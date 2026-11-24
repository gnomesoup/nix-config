"""Single-owner Zulip DM transport for Inigo; credentials stay in systemd."""

import asyncio
import contextlib
import json
import os
import random
from pathlib import Path

import httpx
from gateway.config import Platform
from gateway.platforms.base import BasePlatformAdapter, SendResult
from gateway.platforms.event import MessageEvent
from gateway.platforms.helpers import MessageDeduplicator

SHUTDOWN_TIMEOUT = 2.0


class ZulipError(Exception):
    """Intentionally excludes server bodies, URLs, and credentials."""

    def __init__(self, code="API_ERROR", *, retryable=False, retry_after=None):
        super().__init__("Zulip request failed")
        self.code = code
        self.retryable = retryable
        self.retry_after = retry_after


class ZulipClient:
    def __init__(self, site, bot_email, api_key, *, transport=None):
        self.bot_email = bot_email
        self.http = httpx.AsyncClient(
            base_url=site.rstrip("/") + "/api/v1/",
            auth=httpx.BasicAuth(bot_email, api_key),
            timeout=httpx.Timeout(110, connect=15),
            follow_redirects=False,
            trust_env=False,
            transport=transport,
        )

    async def request(self, method, endpoint, **kwargs):
        try:
            response = await self.http.request(method, endpoint, **kwargs)
        except httpx.HTTPError:
            raise ZulipError("NETWORK_ERROR", retryable=True) from None
        status = response.status_code
        if status in (401, 403):
            raise ZulipError("AUTH_ERROR")
        if status == 429:
            try:
                delay = float(response.headers.get("Retry-After", "1"))
                if not 0 <= delay <= 300:
                    delay = 300.0
            except ValueError:
                delay = 1.0
            raise ZulipError("RATE_LIMIT", retryable=True, retry_after=delay)
        if status >= 500 or 300 <= status < 400:
            raise ZulipError("HTTP_ERROR", retryable=status >= 500)
        try:
            payload = response.json()
        except ValueError:
            raise ZulipError("PROTOCOL_ERROR", retryable=True) from None
        if not isinstance(payload, dict):
            raise ZulipError("PROTOCOL_ERROR", retryable=True)
        if payload.get("code") == "BAD_EVENT_QUEUE_ID":
            raise ZulipError("BAD_EVENT_QUEUE_ID", retryable=True)
        if status >= 400 or payload.get("result") != "success":
            raise ZulipError()
        return payload

    async def resolve_identities(self, allowed_email):
        own = await self.request("GET", "users/me")
        users = await self.request("GET", "users")
        members = users.get("members")
        if not isinstance(members, list):
            raise ZulipError("PROTOCOL_ERROR", retryable=True)
        allowed = [
            user
            for user in members
            if isinstance(user, dict)
            and isinstance(user.get("email"), str)
            and user["email"].casefold() == allowed_email.casefold()
            and user.get("is_active") is True
            and user.get("is_bot") is False
        ]
        if (
            len(allowed) != 1
            or own.get("is_bot") is not True
            or not isinstance(own.get("email"), str)
            or own["email"].casefold() != self.bot_email.casefold()
        ):
            raise ZulipError("IDENTITY_ERROR")
        own_id, allowed_id = own.get("user_id"), allowed[0].get("user_id")
        if (
            type(own_id) is not int
            or type(allowed_id) is not int
            or own_id <= 0
            or allowed_id <= 0
            or own_id == allowed_id
        ):
            raise ZulipError("IDENTITY_ERROR")
        return own_id, allowed_id

    async def close(self):
        await self.http.aclose()


class ZulipAdapter(BasePlatformAdapter):
    def __init__(self, config, *, transport=None):
        super().__init__(config, Platform("zulip"))
        self.site = config.extra.get("site", "https://chat.mmjo.com")
        self.bot_email = config.extra.get("bot_email", "")
        self.allowed_email = config.extra.get("allowed_email", "michael@mmjo.com")
        self._transport = transport
        self._client = None
        self._poll_task = None
        self._queue_id = None
        self._last_event_id = -1
        self._own_id = self._allowed_id = None
        self._dedup = MessageDeduplicator(ttl_seconds=600)

    async def connect(self, *, is_reconnect=False):
        if self._client is not None:
            await self.disconnect()
        self.config.extra["allowed_users"] = []
        try:
            if not validate_config(self.config):
                raise ZulipError("CONFIG_ERROR")
            self._client = ZulipClient(
                self.site, self.bot_email, read_api_key(), transport=self._transport
            )
            self._own_id, self._allowed_id = await self._client.resolve_identities(
                self.allowed_email
            )
            await self._register_queue()
        except ZulipError as error:
            await self.disconnect()
            self._set_fatal_error(
                error.code,
                "Zulip connection failed; check configuration and systemd credential",
                retryable=error.retryable,
            )
            return False
        except asyncio.CancelledError:
            await self.disconnect()
            raise
        self.config.extra["allowed_users"] = [str(self._allowed_id)]
        self._mark_connected()
        self._poll_task = asyncio.create_task(
            self._poll_loop(), name="inigo-zulip-poll"
        )
        return True

    async def _register_queue(self):
        queue = await self._client.request(
            "POST",
            "register",
            data={
                "event_types": json.dumps(["message"]),
                "apply_markdown": "false",
                "narrow": json.dumps([["is", "dm"]]),
                "all_public_streams": "false",
            },
        )
        if (
            not isinstance(queue.get("queue_id"), str)
            or not queue["queue_id"]
            or type(queue.get("last_event_id")) is not int
        ):
            raise ZulipError("PROTOCOL_ERROR", retryable=True)
        self._queue_id = queue["queue_id"]
        self._last_event_id = queue["last_event_id"]

    async def _wait_retry(self, attempt, retry_after=None):
        delay = min(60.0, 2.0 ** min(attempt - 1, 6)) + random.uniform(0, 0.5)
        await asyncio.sleep(max(delay, retry_after or 0))

    async def _poll_loop(self):
        failures = 0
        while self._running:
            try:
                if self._queue_id is None:
                    # Refresh the server-side identity binding whenever the queue is replaced.
                    (
                        self._own_id,
                        self._allowed_id,
                    ) = await self._client.resolve_identities(self.allowed_email)
                    self.config.extra["allowed_users"] = [str(self._allowed_id)]
                    await self._register_queue()
                payload = await self._client.request(
                    "GET",
                    "events",
                    params={
                        "queue_id": self._queue_id,
                        "last_event_id": self._last_event_id,
                        "dont_block": "false",
                    },
                )
                events = payload.get("events")
                if not isinstance(events, list):
                    raise ZulipError("PROTOCOL_ERROR", retryable=True)
                for event in events:
                    if not isinstance(event, dict) or type(event.get("id")) is not int:
                        continue
                    if event["id"] <= self._last_event_id:
                        continue
                    if event.get("type") == "message":
                        message = event.get("message")
                        if accepted_message(
                            message, self._own_id, self._allowed_id
                        ) and not self._dedup.is_duplicate(str(message["id"])):
                            user_id = str(self._allowed_id)
                            source = self.build_source(
                                chat_id=user_id,
                                chat_name=self.allowed_email,
                                chat_type="dm",
                                user_id=user_id,
                                user_name=self.allowed_email,
                            )
                            await self.handle_message(
                                MessageEvent(
                                    text=message["content"],
                                    source=source,
                                    user_id=user_id,
                                    user_name=self.allowed_email,
                                    message_id=str(message["id"]),
                                    raw_message=message,
                                )
                            )
                    self._last_event_id = event["id"]
                failures = 0
            except ZulipError as error:
                if error.code == "BAD_EVENT_QUEUE_ID":
                    self._queue_id = None
                if not error.retryable:
                    self.config.extra["allowed_users"] = []
                    self._own_id = self._allowed_id = None
                    self._set_fatal_error(
                        error.code,
                        "Zulip polling stopped; check bot configuration",
                        retryable=False,
                    )
                    self._mark_disconnected()
                    await self._notify_fatal_error()
                    return
                failures += 1
                await self._wait_retry(failures, error.retry_after)
            except Exception:  # noqa: BLE001 - sanitize all gateway dispatch failures
                # Never let a task die silently while the gateway reports connected.
                # Upstream exception messages can contain request data; don't log them.
                self.config.extra["allowed_users"] = []
                self._own_id = self._allowed_id = None
                self._set_fatal_error(
                    "DISPATCH_ERROR",
                    "Zulip intake failed; reconnect required",
                    retryable=True,
                )
                await self._notify_fatal_error()
                return

    async def disconnect(self):
        self._mark_disconnected()
        if self._poll_task:
            self._poll_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._poll_task
            self._poll_task = None
        await self.cancel_background_tasks()
        if self._client and not self._client.http.is_closed:
            try:
                if self._queue_id:
                    with contextlib.suppress(ZulipError, TimeoutError):
                        await asyncio.wait_for(
                            self._client.request(
                                "DELETE", "events", data={"queue_id": self._queue_id}
                            ),
                            SHUTDOWN_TIMEOUT,
                        )
            finally:
                await self._client.close()
        self._queue_id = None
        self._own_id = self._allowed_id = None
        self.config.extra["allowed_users"] = []

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        if (
            not self._running
            or self._allowed_id is None
            or str(chat_id) != str(self._allowed_id)
        ):
            return SendResult(
                success=False, error="Zulip target is not the configured owner DM"
            )
        if not isinstance(content, str) or not content.strip():
            return SendResult(success=False, error="Zulip message is empty")
        ids = []
        try:
            for offset in range(0, len(content), 10000):
                response = await self._client.request(
                    "POST",
                    "messages",
                    data={
                        "type": "direct",
                        "to": json.dumps([self._allowed_id]),
                        "content": content[offset : offset + 10000],
                    },
                )
                if type(response.get("id")) is not int:
                    raise ZulipError("PROTOCOL_ERROR")
                ids.append(str(response["id"]))
        except ZulipError as error:
            # A timed-out POST may already have succeeded. Never replay a multipart
            # send (or an ambiguous network failure); only a first-chunk 429 is safe.
            return SendResult(
                success=False,
                error="Zulip message delivery failed",
                error_kind=error.code,
                message_id=ids[0] if ids else None,
                continuation_message_ids=tuple(ids[1:]),
                retryable=not ids and error.code == "RATE_LIMIT",
                retry_after=error.retry_after,
            )
        return SendResult(
            success=True, message_id=ids[0], continuation_message_ids=tuple(ids[1:])
        )

    async def get_chat_info(self, chat_id):
        if self._allowed_id is None or str(chat_id) != str(self._allowed_id):
            raise ValueError("Zulip target is not the configured owner DM")
        return {"name": self.allowed_email, "type": "dm"}


def validate_config(config):
    from urllib.parse import urlsplit

    extra = config.extra
    site = extra.get("site", "https://chat.mmjo.com")
    if not isinstance(site, str):
        return False
    try:
        url = urlsplit(site)
        if (
            url.scheme != "https"
            or not url.hostname
            or url.username is not None
            or url.password is not None
            or url.query
            or url.fragment
            or url.path not in ("", "/")
        ):
            return False
        _ = url.port
    except ValueError:
        return False
    for email in (
        extra.get("bot_email"),
        extra.get("allowed_email", "michael@mmjo.com"),
    ):
        if (
            not isinstance(email, str)
            or email.count("@") != 1
            or not all(email.split("@"))
            or any(character.isspace() or character in ":/" for character in email)
        ):
            return False
    return True


def register(ctx):
    ctx.register_platform(
        name="zulip",
        label="Zulip",
        adapter_factory=ZulipAdapter,
        check_fn=lambda: True,
        validate_config=validate_config,
        max_message_length=10000,
        allowlist_suppresses_pairing=True,
        allowed_users_env="ZULIP_ALLOWED_USERS",
        platform_hint="You are chatting in a private Zulip DM. Zulip supports Markdown.",
    )


def accepted_message(message, own_id, allowed_id):
    """The authenticated API's numeric principal wins; event email is never trusted."""
    if not isinstance(message, dict):
        return False
    recipients = message.get("display_recipient")
    if not isinstance(recipients, list) or len(recipients) != 2:
        return False
    if any(
        not isinstance(user, dict) or type(user.get("id")) is not int
        for user in recipients
    ):
        return False
    return (
        own_id is not None
        and allowed_id is not None
        and message.get("type") == "private"
        and type(message.get("sender_id")) is int
        and message["sender_id"] == allowed_id
        and message.get("sender_is_bot") is not True
        and {user["id"] for user in recipients} == {own_id, allowed_id}
        and isinstance(message.get("content"), str)
        and bool(message["content"].strip())
        and type(message.get("id")) is int
        and message["id"] > 0
    )


def read_api_key():
    """Do not fall back to config, environment secrets, or a user's zuliprc."""
    try:
        key = (
            (Path(os.environ["CREDENTIALS_DIRECTORY"]) / "inigo-zulip-api-key")
            .read_text()
            .strip()
        )
    except (OSError, KeyError, UnicodeError):
        raise ZulipError("CREDENTIAL_ERROR") from None
    if not key or "\n" in key or "\r" in key:
        raise ZulipError("CREDENTIAL_ERROR")
    return key

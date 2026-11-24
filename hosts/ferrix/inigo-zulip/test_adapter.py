"""Contract tests run with the installed Hermes Python, without live credentials."""

import asyncio
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx
from gateway.config import PlatformConfig

ROOT = Path(os.environ.get("INIGO_ZULIP_PLUGIN_DIR", Path(__file__).parent))
try:
    spec = importlib.util.spec_from_file_location(
        "inigo_zulip_adapter", ROOT / "adapter.py"
    )
    adapter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(adapter)
except FileNotFoundError:
    adapter = None


class CredentialTests(unittest.TestCase):
    def test_reads_only_named_systemd_credential(self):
        self.assertIsNotNone(adapter, "Zulip adapter is not implemented")
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory:
            Path(directory, "inigo-zulip-api-key").write_text("test-secret\n")
            with patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": directory}):
                self.assertEqual(adapter.read_api_key(), "test-secret")

    def test_missing_empty_or_multiline_credentials_fail_safely(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(adapter.ZulipError) as caught:
                adapter.read_api_key()
            self.assertEqual(str(caught.exception), "Zulip request failed")
        with (
            tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory,
            patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": directory}),
        ):
            for value in [None, "", "  \n", "test-secret\nsecond-line"]:
                if value is not None:
                    Path(directory, "inigo-zulip-api-key").write_text(value)
                with self.subTest(value=value), self.assertRaises(adapter.ZulipError):
                    adapter.read_api_key()


class ConfigurationTests(unittest.TestCase):
    def test_rejects_unsafe_site_or_missing_emails(self):
        self.assertTrue(
            hasattr(adapter, "validate_config"), "Configuration validation is missing"
        )
        self.assertTrue(
            adapter.validate_config(
                PlatformConfig(extra={"bot_email": "inigo@example.com"})
            )
        )
        for extra in [
            {},
            {"bot_email": "bad"},
            {"bot_email": "bot@example.com", "allowed_email": "*"},
            *[
                {"bot_email": "bot@example.com", "site": site}
                for site in [
                    "http://chat.mmjo.com",
                    "https://user:secret@chat.mmjo.com",
                    "https://chat.mmjo.com/?key=secret",
                    "https://chat.mmjo.com/#secret",
                    "https://chat.mmjo.com/api/v1",
                    "https://",
                    None,
                ]
            ],
        ]:
            with self.subTest(extra=extra):
                self.assertFalse(adapter.validate_config(PlatformConfig(extra=extra)))


class IdentityTests(unittest.IsolatedAsyncioTestCase):
    async def test_resolves_owner_by_server_id_not_event_email(self):
        self.assertTrue(hasattr(adapter, "ZulipClient"), "HTTP client is missing")
        paths = []

        def serve(request):
            paths.append(request.url.path)
            self.assertEqual(
                request.headers["authorization"],
                "Basic aW5pZ29AZXhhbXBsZS5jb206dGVzdC1zZWNyZXQ=",
            )
            if request.url.path.endswith("/users/me"):
                return httpx.Response(
                    200,
                    json={
                        "result": "success",
                        "user_id": 9,
                        "email": "inigo@example.com",
                        "is_bot": True,
                    },
                )
            return httpx.Response(
                200,
                json={
                    "result": "success",
                    "members": [
                        {
                            "user_id": 23,
                            "email": "michael@mmjo.com",
                            "is_bot": False,
                            "is_active": True,
                        },
                        {
                            "user_id": 24,
                            "email": "other@example.com",
                            "is_bot": False,
                            "is_active": True,
                        },
                    ],
                },
            )

        client = adapter.ZulipClient(
            "https://chat.mmjo.com",
            "inigo@example.com",
            "test-secret",
            transport=httpx.MockTransport(serve),
        )
        try:
            self.assertEqual(
                await client.resolve_identities("michael@mmjo.com"), (9, 23)
            )
            self.assertEqual(paths, ["/api/v1/users/me", "/api/v1/users"])
        finally:
            await client.close()

    async def test_identity_payloads_fail_closed_for_malformed_or_non_bot_accounts(
        self,
    ):
        valid_own = {"user_id": 9, "email": "inigo@example.com", "is_bot": True}
        valid_owner = {
            "user_id": 23,
            "email": "michael@mmjo.com",
            "is_bot": False,
            "is_active": True,
        }
        cases = [
            ({**valid_own, "is_bot": False}, [valid_owner]),
            (valid_own, None),
            (valid_own, [None]),
            (valid_own, [{**valid_owner, "email": None}]),
            (valid_own, [valid_owner, valid_owner]),
            (valid_own, [{**valid_owner, "is_active": False}]),
        ]
        for own, members in cases:

            def serve(request, own=own, members=members):
                return httpx.Response(
                    200,
                    json={
                        "result": "success",
                        **(
                            own
                            if request.url.path.endswith("/me")
                            else {"members": members}
                        ),
                    },
                )

            client = adapter.ZulipClient(
                "https://chat.mmjo.com",
                "inigo@example.com",
                "test-secret",
                transport=httpx.MockTransport(serve),
            )
            try:
                with (
                    self.subTest(own=own, members=members),
                    self.assertRaises(adapter.ZulipError),
                ):
                    await client.resolve_identities("michael@mmjo.com")
            finally:
                await client.close()

    async def test_http_failures_are_sanitized_and_classified(self):
        cases = [
            (
                httpx.Response(
                    400,
                    json={
                        "result": "error",
                        "code": "BAD_EVENT_QUEUE_ID",
                        "msg": "test-secret",
                    },
                ),
                "BAD_EVENT_QUEUE_ID",
                True,
                None,
            ),
            (
                httpx.Response(
                    429,
                    headers={"Retry-After": "2"},
                    json={"result": "error", "msg": "test-secret"},
                ),
                "RATE_LIMIT",
                True,
                2.0,
            ),
            (httpx.Response(503, text="test-secret"), "HTTP_ERROR", True, None),
            (httpx.Response(401, text="test-secret"), "AUTH_ERROR", False, None),
            (httpx.Response(200, text="test-secret"), "PROTOCOL_ERROR", True, None),
        ]
        for response, code, retryable, retry_after in cases:
            with self.subTest(code=code):
                client = adapter.ZulipClient(
                    "https://chat.mmjo.com",
                    "inigo@example.com",
                    "test-secret",
                    transport=httpx.MockTransport(
                        lambda request, response=response: response
                    ),
                )
                try:
                    with self.assertRaises(adapter.ZulipError) as caught:
                        await client.request("GET", "events")
                    self.assertEqual(caught.exception.code, code)
                    self.assertEqual(caught.exception.retryable, retryable)
                    self.assertEqual(caught.exception.retry_after, retry_after)
                    self.assertNotIn("test-secret", str(caught.exception))
                finally:
                    await client.close()

        def fail(request):
            raise httpx.ConnectError("test-secret")

        client = adapter.ZulipClient(
            "https://chat.mmjo.com",
            "inigo@example.com",
            "test-secret",
            transport=httpx.MockTransport(fail),
        )
        try:
            with self.assertRaises(adapter.ZulipError) as caught:
                await client.request("GET", "events")
            self.assertEqual(caught.exception.code, "NETWORK_ERROR")
            self.assertNotIn("test-secret", str(caught.exception))
        finally:
            await client.close()


class InboundTests(unittest.TestCase):
    def test_accepts_only_owner_one_to_one_dm_by_numeric_ids(self):
        self.assertTrue(hasattr(adapter, "accepted_message"), "DM filter is missing")
        valid = {
            "id": 101,
            "type": "private",
            "sender_id": 23,
            "sender_email": "untrusted@example.com",
            "content": "hello",
            "display_recipient": [{"id": 9}, {"id": 23}],
        }
        self.assertTrue(adapter.accepted_message(valid, 9, 23))
        for change in [
            {"type": "stream"},
            {"sender_id": 9},
            {"sender_id": 24, "sender_email": "michael@mmjo.com"},
            {"sender_id": "23"},
            {"sender_id": True},
            {"sender_is_bot": True},
            {"display_recipient": [{"id": 9}, {"id": 23}, {"id": 24}]},
            {"display_recipient": [{"id": 23}]},
            {"display_recipient": [{"id": 9}, {"id": 24}]},
            {"display_recipient": "bad"},
            {"display_recipient": [None, {"id": 9}]},
            {"content": ""},
            {"content": None},
            {"id": "101"},
        ]:
            with self.subTest(change=change):
                self.assertFalse(adapter.accepted_message({**valid, **change}, 9, 23))


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def test_connect_delivers_dm_through_hermes_and_sends_reply(self):
        self.assertTrue(hasattr(adapter, "ZulipAdapter"), "Gateway adapter is missing")
        import json
        from types import SimpleNamespace
        from urllib.parse import parse_qs

        from gateway.authz_mixin import GatewayAuthorizationMixin
        from gateway.platform_registry import PlatformEntry, platform_registry

        class Context:
            def register_platform(self, **kwargs):
                platform_registry.register(PlatformEntry(source="plugin", **kwargs))

        adapter.register(Context())
        calls, received = [], []
        delivered = asyncio.Event()

        async def serve(request):
            calls.append((request.method, request.url.path))
            if request.url.path.endswith("/users/me"):
                payload = {"user_id": 9, "email": "inigo@example.com", "is_bot": True}
            elif request.url.path.endswith("/users"):
                payload = {
                    "members": [
                        {
                            "user_id": 23,
                            "email": "michael@mmjo.com",
                            "is_bot": False,
                            "is_active": True,
                        }
                    ]
                }
            elif request.url.path.endswith("/register"):
                data = parse_qs(request.content.decode())
                self.assertEqual(json.loads(data["event_types"][0]), ["message"])
                self.assertEqual(data["apply_markdown"], ["false"])
                self.assertEqual(json.loads(data["narrow"][0]), [["is", "dm"]])
                payload = {"queue_id": "q1", "last_event_id": -1}
            elif request.url.path.endswith("/events") and not delivered.is_set():
                delivered.set()
                payload = {
                    "events": [
                        {
                            "id": 0,
                            "type": "message",
                            "message": {
                                "id": 101,
                                "type": "private",
                                "sender_id": 23,
                                "content": "hello **Inigo**",
                                "display_recipient": [{"id": 9}, {"id": 23}],
                            },
                        }
                    ]
                }
            elif request.url.path.endswith("/messages"):
                data = parse_qs(request.content.decode())
                self.assertEqual(data["type"], ["direct"])
                self.assertEqual(json.loads(data["to"][0]), [23])
                self.assertEqual(data["content"], ["reply"])
                payload = {"id": 102}
            elif request.method == "DELETE":
                payload = {}
            else:
                await asyncio.Event().wait()
            return httpx.Response(200, json={"result": "success", **payload})

        config = PlatformConfig(enabled=True, extra={"bot_email": "inigo@example.com"})
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory:
            Path(directory, "inigo-zulip-api-key").write_text("test-secret")
            Path(directory, "config.yaml").write_text("{}")
            with (
                patch.dict(
                    os.environ,
                    {"CREDENTIALS_DIRECTORY": directory, "HERMES_HOME": directory},
                ),
                patch("hermes_cli.plugins.discover_plugins"),
                patch.object(adapter.ZulipAdapter, "_write_runtime_status_safe"),
            ):
                instance = adapter.ZulipAdapter(
                    config, transport=httpx.MockTransport(serve)
                )

                async def receive(event):
                    received.append(event)

                # Spy only on dispatch: test the real source/event construction and HTTP.
                instance.handle_message = receive
                try:
                    self.assertTrue(await instance.connect())
                    for _ in range(50):
                        if received:
                            break
                        await asyncio.sleep(0.001)
                    self.assertEqual(len(received), 1)
                    event = received[0]
                    self.assertEqual(
                        (
                            event.text,
                            event.source.user_id,
                            event.source.chat_id,
                            event.message_id,
                        ),
                        ("hello **Inigo**", "23", "23", "101"),
                    )
                    self.assertEqual(config.extra["allowed_users"], ["23"])
                    runner = GatewayAuthorizationMixin()
                    runner.adapters = {instance.platform: instance}
                    runner.config = SimpleNamespace(
                        platforms={instance.platform: config}, multiplex_profiles=False
                    )
                    self.assertTrue(runner._is_user_authorized(event.source))
                    denied = instance.build_source(
                        chat_id="24", user_id="24", chat_type="dm"
                    )
                    self.assertFalse(runner._is_user_authorized(denied))
                    result = await instance.send("23", "reply")
                    self.assertTrue(result.success)
                    self.assertEqual(result.message_id, "102")
                    self.assertEqual(
                        await instance.get_chat_info("23"),
                        {"name": "michael@mmjo.com", "type": "dm"},
                    )
                finally:
                    await instance.disconnect()
                self.assertTrue(instance._client.http.is_closed)
                self.assertFalse(instance._running)
                self.assertIn(("DELETE", "/api/v1/events"), calls)


class ReliabilityTests(unittest.IsolatedAsyncioTestCase):
    @staticmethod
    def registration():
        from gateway.platform_registry import PlatformEntry, platform_registry

        class Context:
            def register_platform(self, **kwargs):
                platform_registry.register(PlatformEntry(source="plugin", **kwargs))

        adapter.register(Context())

    @staticmethod
    def success(**fields):
        return httpx.Response(200, json={"result": "success", **fields})

    def fixture(self, serve):
        from contextlib import asynccontextmanager

        @asynccontextmanager
        async def context():
            self.registration()
            with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory:
                Path(directory, "inigo-zulip-api-key").write_text("test-secret")
                with (
                    patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": directory}),
                    patch.object(adapter.ZulipAdapter, "_write_runtime_status_safe"),
                ):
                    instance = adapter.ZulipAdapter(
                        PlatformConfig(
                            enabled=True, extra={"bot_email": "inigo@example.com"}
                        ),
                        transport=httpx.MockTransport(serve),
                    )
                    try:
                        yield instance
                    finally:
                        await instance.disconnect()

        return context()

    async def test_failed_connect_closes_client_and_leaves_no_authorized_principal(
        self,
    ):
        for failure in ["auth", "bot-owner", "register", "malformed-queue"]:

            async def serve(request, failure=failure):
                if failure == "auth" and request.url.path.endswith("/users/me"):
                    return httpx.Response(401, text="test-secret")
                if failure == "bot-owner" and request.url.path.endswith("/users"):
                    return self.success(
                        members=[
                            {
                                "user_id": 23,
                                "email": "michael@mmjo.com",
                                "is_active": True,
                                "is_bot": True,
                            }
                        ]
                    )
                if request.url.path.endswith("/register"):
                    if failure == "register":
                        return httpx.Response(503, text="test-secret")
                    if failure == "malformed-queue":
                        return self.success(queue_id=None)
                return await self.standard(request)

            async with self.fixture(serve) as instance:
                with self.subTest(failure=failure):
                    self.assertFalse(await instance.connect())
                    self.assertTrue(instance._client.http.is_closed)
                    self.assertIsNone(instance._poll_task)
                    self.assertIsNone(instance._allowed_id)
                    self.assertEqual(instance.config.extra["allowed_users"], [])
                    self.assertFalse(instance._running)
                    self.assertNotIn("test-secret", instance.fatal_error_message)

    async def test_dispatch_exception_notifies_gateway_for_reconnect_without_leaking(
        self,
    ):
        message = {
            "id": 101,
            "type": "private",
            "sender_id": 23,
            "content": "hello",
            "display_recipient": [{"id": 9}, {"id": 23}],
        }

        async def serve(request):
            if request.method == "GET" and request.url.path.endswith("/events"):
                return self.success(
                    events=[{"id": 0, "type": "message", "message": message}]
                )
            return await self.standard(request)

        async with self.fixture(serve) as instance:
            notifications = []

            async def receive(event):
                raise RuntimeError("test-secret")

            async def failed(current):
                notifications.append(current.fatal_error_code)

            instance.handle_message = receive
            instance.set_fatal_error_handler(failed)
            await instance.connect()
            await asyncio.wait_for(asyncio.shield(instance._poll_task), 1)
            self.assertEqual(notifications, ["DISPATCH_ERROR"])
            self.assertTrue(instance.fatal_error_retryable)
            self.assertFalse(instance._running)
            self.assertNotIn("test-secret", instance.fatal_error_message)

    async def test_malformed_poll_recovers_and_auth_revocation_stops_intake(self):
        polls, retries = [], []

        async def serve(request):
            if request.method == "GET" and request.url.path.endswith("/events"):
                polls.append(request)
                if len(polls) == 1:
                    return self.success(events=None)
                if len(polls) == 2:
                    return self.success(
                        events=[None, {"id": "bad"}, {"id": 1, "type": "heartbeat"}]
                    )
                return httpx.Response(401, text="test-secret")
            return await self.standard(request)

        async with self.fixture(serve) as instance:

            async def wait_retry(attempt, retry_after=None):
                retries.append(attempt)

            instance._wait_retry = wait_retry
            await instance.connect()
            await asyncio.wait_for(asyncio.shield(instance._poll_task), 1)
            self.assertEqual(retries, [1])
            self.assertEqual(instance.fatal_error_code, "AUTH_ERROR")
            self.assertFalse(instance._running)
            self.assertEqual(instance.config.extra["allowed_users"], [])
            self.assertNotIn("test-secret", instance.fatal_error_message)

    async def test_shutdown_cancels_longpoll_and_bounds_queue_deletion(self):
        deletes = []

        async def serve(request):
            if request.method == "DELETE":
                deletes.append(request)
                if len(deletes) == 1:
                    await asyncio.Event().wait()
                return self.success()
            return await self.standard(request)

        async with self.fixture(serve) as instance:
            await instance.connect()
            with patch.object(adapter, "SHUTDOWN_TIMEOUT", 0.01, create=True):
                await asyncio.wait_for(instance.disconnect(), 0.1)
            self.assertIsNone(instance._poll_task)
            self.assertTrue(instance._client.http.is_closed)
            self.assertFalse(instance._running)

    async def test_partial_send_failure_is_reported_without_unsafe_retries_or_secret(
        self,
    ):
        sends = []

        async def serve(request):
            if request.url.path.endswith("/messages"):
                sends.append(request)
                if len(sends) == 1:
                    return self.success(id=101)
                raise httpx.ReadTimeout("test-secret")
            return await self.standard(request)

        async with self.fixture(serve) as instance:
            await instance.connect()
            result = await instance.send("23", "x" * 10001)
            self.assertFalse(result.success)
            self.assertEqual(result.message_id, "101")
            self.assertFalse(result.retryable)
            self.assertEqual(result.error_kind, "NETWORK_ERROR")
            self.assertNotIn("test-secret", result.error)
            self.assertEqual(len(sends), 2)

    async def test_send_is_owner_only_and_splits_long_unicode_without_loss(self):
        from urllib.parse import parse_qs

        bodies = []

        async def serve(request):
            if request.url.path.endswith("/messages"):
                bodies.append(parse_qs(request.content.decode()))
                return self.success(id=100 + len(bodies))
            return await self.standard(request)

        async with self.fixture(serve) as instance:
            await instance.connect()
            rejected = await instance.send("24", "must not leave")
            self.assertFalse(rejected.success)
            self.assertEqual(bodies, [])
            text = "🙂" * 10001
            result = await instance.send("23", text)
            self.assertTrue(result.success)
            self.assertEqual([len(body["content"][0]) for body in bodies], [10000, 1])
            self.assertEqual("".join(body["content"][0] for body in bodies), text)
            self.assertEqual(result.message_id, "101")
            self.assertEqual(result.continuation_message_ids, ("102",))
            self.assertFalse((await instance.send("23", "")).success)
            self.assertEqual(len(bodies), 2)
            with self.assertRaises(ValueError):
                await instance.get_chat_info("24")

    async def standard(self, request):
        path = request.url.path
        if path.endswith("/users/me"):
            return self.success(user_id=9, email="inigo@example.com", is_bot=True)
        if path.endswith("/users"):
            return self.success(
                members=[
                    {
                        "user_id": 23,
                        "email": "michael@mmjo.com",
                        "is_active": True,
                        "is_bot": False,
                    }
                ]
            )
        if path.endswith("/register"):
            return self.success(queue_id="q1", last_event_id=-1)
        if request.method == "DELETE":
            return self.success()
        await asyncio.Event().wait()

    async def test_recovers_expired_queue_with_backoff_and_deduplicates(self):
        self.assertTrue(
            hasattr(adapter.ZulipAdapter, "_wait_retry"),
            "Polling retry/backoff is missing",
        )
        queues, polls, delays, received = [], [], [], []
        reached = asyncio.Event()
        message = {
            "id": 101,
            "type": "private",
            "sender_id": 23,
            "content": "hello",
            "display_recipient": [{"id": 9}, {"id": 23}],
        }

        async def serve(request):
            path = request.url.path
            if path.endswith("/users/me"):
                return self.success(user_id=9, email="inigo@example.com", is_bot=True)
            if path.endswith("/users"):
                return self.success(
                    members=[
                        {
                            "user_id": 23,
                            "email": "michael@mmjo.com",
                            "is_active": True,
                            "is_bot": False,
                        }
                    ]
                )
            if path.endswith("/register"):
                queues.append("q" + str(len(queues) + 1))
                return self.success(queue_id=queues[-1], last_event_id=-1)
            if request.method == "DELETE":
                return self.success()
            polls.append(dict(request.url.params))
            if len(polls) == 1:
                return self.success(
                    events=[{"id": 0, "type": "message", "message": message}]
                )
            if len(polls) == 2:
                raise httpx.ReadTimeout("test-secret")
            if len(polls) == 3:
                return httpx.Response(
                    429, headers={"Retry-After": "2"}, json={"result": "error"}
                )
            if len(polls) == 4:
                return httpx.Response(
                    400, json={"result": "error", "code": "BAD_EVENT_QUEUE_ID"}
                )
            if len(polls) == 5:
                return self.success(
                    events=[
                        {"id": 1, "type": "message", "message": message},
                        {"id": 2, "type": "message", "message": {**message, "id": 102}},
                    ]
                )
            reached.set()
            await asyncio.Event().wait()

        async with self.fixture(serve) as instance:

            async def receive(event):
                received.append(event.message_id)

            async def wait_retry(attempt, retry_after=None):
                delays.append((attempt, retry_after))

            instance.handle_message = receive
            instance._wait_retry = wait_retry
            await instance.connect()
            await asyncio.wait_for(reached.wait(), 1)
            self.assertEqual(queues, ["q1", "q2"])
            self.assertEqual(received, ["101", "102"])
            self.assertEqual(polls[1]["last_event_id"], "0")
            self.assertEqual(polls[4]["queue_id"], "q2")
            self.assertEqual(polls[4]["last_event_id"], "-1")
            self.assertEqual(delays[:2], [(1, None), (2, 2.0)])


class PluginTests(unittest.TestCase):
    def test_loads_under_nix_managed_directory_with_distinct_platform_name(self):
        self.assertTrue((ROOT / "plugin.yaml").exists(), "Plugin manifest is missing")
        from gateway.platform_registry import platform_registry
        from hermes_cli.plugins import PluginManager
        from hermes_cli.plugins_discovery import scan_directory

        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory:
            home = Path(directory)
            (home / "plugins").mkdir()
            for subdir in ("cron", "sessions", "logs", "memories"):
                (home / subdir).mkdir()
            (home / "plugins" / "nix-managed-inigo-zulip-plugin").symlink_to(
                ROOT, target_is_directory=True
            )
            (home / "config.yaml").write_text("plugins:\n  enabled: [inigo-zulip]\n")
            with patch.dict(os.environ, {"HERMES_HOME": directory}):
                manifests = scan_directory(home / "plugins", "user")
                self.assertEqual(len(manifests), 1)
                self.assertEqual(manifests[0].name, "inigo-zulip")
                # The installed loader derives deferred names from directory basenames.
                # A standalone manifest eagerly registers the real 'zulip' platform.
                self.assertEqual(manifests[0].kind, "standalone")
                manager = PluginManager(scope_key=directory)
                try:
                    manager._load_plugin(manifests[0])
                    entry = platform_registry.get("zulip")
                    self.assertIsNotNone(entry)
                    self.assertEqual(entry.plugin_name, "inigo-zulip")
                    self.assertFalse(entry.trusted_inbound)
                    self.assertTrue(
                        entry.validate_config(
                            PlatformConfig(extra={"bot_email": "inigo@example.com"})
                        )
                    )
                    self.assertEqual(entry.allowed_users_env, "ZULIP_ALLOWED_USERS")
                    instance = platform_registry.create_adapter(
                        "zulip",
                        PlatformConfig(extra={"bot_email": "inigo@example.com"}),
                    )
                    self.assertEqual(instance.platform.value, "zulip")
                finally:
                    manager.unload("inigo-zulip")


if __name__ == "__main__":
    unittest.main()

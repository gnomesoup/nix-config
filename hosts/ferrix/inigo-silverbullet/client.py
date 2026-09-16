"""Safe, dependency-free SilverBullet 2.10 HTTP client for Inigo."""

from __future__ import annotations

import json
import os
import re
import stat
import threading
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

REQUEST_TIMEOUT_SECONDS = 15
HARD_MAX_LIST_BYTES = 5 * 1024 * 1024
HARD_MAX_CONTENT_BYTES = 2 * 1024 * 1024
HARD_MAX_SEARCH_BYTES = 64 * 1024 * 1024
HARD_MAX_RESULT_CHARS = 50_000
TEXT_EXTENSIONS = {"md", "txt", "json", "yaml", "yml"}
SYSTEM_ROOTS = {"library", "repositories", ".client"}


class SilverBulletError(RuntimeError):
    """A safe error suitable for returning from a tool handler."""


class MissingPageError(SilverBulletError):
    pass


class ConflictError(SilverBulletError):
    pass


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


@dataclass(frozen=True)
class Metadata:
    created: int | None = None
    last_modified: int | None = None
    content_type: str | None = None
    size: int | None = None
    permission: str | None = None
    etag: str | None = None


@dataclass(frozen=True)
class Snapshot:
    page: str
    content: str
    body: bytes
    metadata: Metadata


@dataclass(frozen=True)
class Space:
    name: str
    label: str
    base_url: str
    read_prefixes: tuple[str, ...]
    write_prefixes: tuple[str, ...]


@dataclass(frozen=True)
class ClientConfig:
    base_url: str
    token_file: Path
    systemd_credential: bool
    default_space: str
    spaces: dict[str, Space]
    max_content_bytes: int
    max_search_bytes: int
    max_result_chars: int


def _integer(value: Any, label: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise SilverBulletError(f"SilverBullet setting {label} must be an integer from {minimum} to {maximum}.")
    return value


def _normalize_prefix(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise SilverBulletError(f"{label} must contain strings.")
    prefix = value.strip().replace("\\", "/").strip("/")
    if prefix == "":
        return ""
    parts = prefix.split("/")
    if any(not part or part in {".", ".."} for part in parts):
        raise SilverBulletError(f"{label} contains an invalid path prefix.")
    if any("?" in part or "#" in part or any(ord(char) < 32 or ord(char) == 127 for char in part) for part in parts):
        raise SilverBulletError(f"{label} contains invalid characters.")
    return "/".join(parts)


def _prefixes(value: Any, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise SilverBulletError(f"{label} must be a non-empty list of path prefixes.")
    return tuple(dict.fromkeys(_normalize_prefix(item, label) for item in value))


def _path_allowed(page: str, prefixes: tuple[str, ...]) -> bool:
    folded = page.casefold()
    return any(
        prefix == ""
        or folded == prefix.casefold()
        or folded.startswith(f"{prefix.casefold()}/")
        for prefix in prefixes
    )


def normalize_page(raw: Any) -> str:
    if not isinstance(raw, str):
        raise SilverBulletError("SilverBullet page must be a string.")
    page = raw.strip().replace("\\", "/")
    while page.startswith("./"):
        page = page[2:]
    if not page or page.startswith("/"):
        raise SilverBulletError("SilverBullet page must be a non-empty relative path.")
    if "?" in page or "#" in page or any(ord(char) < 32 or ord(char) == 127 for char in page):
        raise SilverBulletError("SilverBullet page contains invalid characters.")
    parts = page.split("/")
    if any(not part or part in {".", ".."} for part in parts):
        raise SilverBulletError("SilverBullet page contains an invalid path segment.")
    if "." not in parts[-1]:
        page += ".md"
    return page


def normalize_listing_prefix(raw: Any) -> str:
    if raw is None:
        return ""
    return _normalize_prefix(raw, "SilverBullet prefix")


def is_system_path(page: str) -> bool:
    root = page.split("/", 1)[0].casefold()
    return root in SYSTEM_ROOTS or root.startswith(".")


def _space_path(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.startswith("/"):
        raise SilverBulletError(f"SilverBullet space {name} path must start with /.")
    if (
        (value != "/" and value.endswith("/"))
        or "\\" in value
        or "//" in value
        or "%" in value
        or "?" in value
        or "#" in value
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        raise SilverBulletError(f"SilverBullet space {name} path must be a canonical URL prefix.")
    parts = value[1:].split("/") if value != "/" else []
    if any(not part or part in {".", ".."} or part.startswith(".") for part in parts):
        raise SilverBulletError(f"SilverBullet space {name} path contains a reserved segment.")
    return value


def parse_config(settings: Any, environ: dict[str, str] | None = None) -> ClientConfig:
    if not isinstance(settings, dict):
        raise SilverBulletError("SilverBullet plugin settings must be an object.")
    environ = os.environ if environ is None else environ
    base_url = settings.get("base_url", "http://127.0.0.1:3000")
    if not isinstance(base_url, str):
        raise SilverBulletError("SilverBullet base_url must be a string.")
    parsed = urlsplit(base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise SilverBulletError("SilverBullet base_url must be an HTTP(S) origin.")
    if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in {"", "/"}:
        raise SilverBulletError("SilverBullet base_url must not contain credentials, a path, query, or fragment.")
    if (
        parsed.scheme == "http"
        and parsed.hostname not in {"127.0.0.1", "::1", "localhost"}
        and settings.get("allow_insecure_http") is not True
    ):
        raise SilverBulletError("Plain HTTP outside loopback requires allow_insecure_http=true.")
    base_url = base_url.rstrip("/")

    configured_token_file = settings.get("token_file")
    systemd_credential = False
    if configured_token_file is None:
        credential_directory = environ.get("CREDENTIALS_DIRECTORY", "")
        if not credential_directory:
            credential_directory = "/run/credentials/hermes-agent.service"
        else:
            systemd_credential = True
        token_file = Path(credential_directory) / "silverbullet-api-token"
    elif isinstance(configured_token_file, str) and Path(configured_token_file).is_absolute():
        token_file = Path(configured_token_file)
    else:
        raise SilverBulletError("SilverBullet token_file must be an absolute path when configured.")

    raw_spaces = settings.get("spaces")
    if not isinstance(raw_spaces, dict) or not raw_spaces:
        raise SilverBulletError("SilverBullet spaces must be a non-empty object.")
    spaces: dict[str, Space] = {}
    paths: set[str] = set()
    for name, raw in raw_spaces.items():
        if not isinstance(name, str) or re.fullmatch(r"[a-z][a-z0-9_-]*", name) is None:
            raise SilverBulletError(f"Invalid SilverBullet space name: {name!r}.")
        if not isinstance(raw, dict):
            raise SilverBulletError(f"SilverBullet space {name} must be an object.")
        label = raw.get("label")
        if not isinstance(label, str) or not label.strip():
            raise SilverBulletError(f"SilverBullet space {name} requires a label.")
        path = _space_path(raw.get("path"), name)
        if path in paths:
            raise SilverBulletError(f"SilverBullet space path is configured twice: {path}.")
        paths.add(path)
        read_prefixes = _prefixes(raw.get("allowed_read_paths", [""]), f"spaces.{name}.allowed_read_paths")
        write_prefixes = _prefixes(raw.get("allowed_write_paths", [""]), f"spaces.{name}.allowed_write_paths")
        if any(
            not any(
                read_prefix == ""
                or write_prefix == read_prefix
                or write_prefix.startswith(f"{read_prefix}/")
                for read_prefix in read_prefixes
            )
            for write_prefix in write_prefixes
        ):
            raise SilverBulletError(f"SilverBullet space {name} write paths must be contained in its read paths.")
        spaces[name] = Space(
            name=name,
            label=label.strip(),
            base_url=base_url if path == "/" else f"{base_url}{path}",
            read_prefixes=read_prefixes,
            write_prefixes=write_prefixes,
        )
    non_root = [path for path in paths if path != "/"]
    if any(left != right and right.startswith(f"{left}/") for left in non_root for right in non_root):
        raise SilverBulletError("SilverBullet non-root space paths must not be nested.")

    default_space = settings.get("default_space")
    if not isinstance(default_space, str) or default_space not in spaces:
        raise SilverBulletError("SilverBullet default_space must name a configured space.")
    return ClientConfig(
        base_url=base_url,
        token_file=token_file,
        systemd_credential=systemd_credential,
        default_space=default_space,
        spaces=spaces,
        max_content_bytes=_integer(
            settings.get("max_content_bytes", HARD_MAX_CONTENT_BYTES),
            "max_content_bytes",
            1,
            HARD_MAX_CONTENT_BYTES,
        ),
        max_search_bytes=_integer(
            settings.get("max_search_bytes", HARD_MAX_SEARCH_BYTES),
            "max_search_bytes",
            1,
            HARD_MAX_SEARCH_BYTES,
        ),
        max_result_chars=_integer(
            settings.get("max_result_chars", HARD_MAX_RESULT_CHARS),
            "max_result_chars",
            1000,
            HARD_MAX_RESULT_CHARS,
        ),
    )


class SilverBulletClient:
    def __init__(self, config: ClientConfig):
        self.config = config
        self._opener = build_opener(_NoRedirect())
        self._mutation_lock = threading.RLock()

    def available(self) -> bool:
        try:
            self._token()
            return True
        except SilverBulletError:
            return False

    def _token(self) -> str:
        try:
            info = self.config.token_file.stat()
            if not stat.S_ISREG(info.st_mode):
                raise SilverBulletError("SilverBullet credential is not a regular file.")
            insecure_permissions = info.st_mode & (stat.S_IWGRP | stat.S_IXGRP | stat.S_IRWXO)
            acl_mask_read = info.st_mode & stat.S_IRGRP
            if insecure_permissions or (acl_mask_read and not self.config.systemd_credential):
                raise SilverBulletError("SilverBullet credential must not be accessible by group or other users.")
            token = self.config.token_file.read_text(encoding="utf-8").strip()
        except SilverBulletError:
            raise
        except OSError as error:
            raise SilverBulletError("SilverBullet credential is unavailable.") from error
        if not token:
            raise SilverBulletError("SilverBullet credential is empty.")
        return token

    def space(self, requested: Any = None) -> Space:
        name = self.config.default_space if requested is None else requested
        if not isinstance(name, str) or name not in self.config.spaces:
            raise SilverBulletError(f"Unknown SilverBullet space: {name!r}.")
        return self.config.spaces[name]

    @staticmethod
    def _encoded_page(page: str) -> str:
        return "/".join(quote(part, safe="") for part in page.split("/"))

    def _url(self, space: Space, page: str | None = None) -> str:
        return f"{space.base_url}/.fs" if page is None else f"{space.base_url}/.fs/{self._encoded_page(page)}"

    @staticmethod
    def _read_limited(response, limit: int) -> bytes:
        declared = response.headers.get("Content-Length")
        if declared:
            try:
                if int(declared) > limit:
                    raise SilverBulletError(f"SilverBullet response exceeds the {limit}-byte limit.")
            except ValueError:
                pass
        chunks: list[bytes] = []
        length = 0
        while True:
            chunk = response.read(min(64 * 1024, limit + 1 - length))
            if not chunk:
                break
            length += len(chunk)
            if length > limit:
                raise SilverBulletError(f"SilverBullet response exceeds the {limit}-byte limit.")
            chunks.append(chunk)
        return b"".join(chunks)

    def _request(
        self,
        space: Space,
        method: str,
        page: str | None = None,
        body: bytes | None = None,
        metadata: Metadata | None = None,
    ):
        token = self._token()
        headers = {
            "Accept": "application/json" if page is None else "application/octet-stream",
            "Authorization": f"Bearer {token}",
            "X-Sync-Mode": "true",
        }
        if metadata and metadata.etag:
            headers["If-Match"] = metadata.etag
        if body is not None:
            now = int(time.time() * 1000)
            if metadata and metadata.last_modified is not None:
                now = max(now, metadata.last_modified + 1)
            headers.update(
                {
                    "Content-Type": metadata.content_type if metadata and metadata.content_type else "text/markdown",
                    "X-Created": str(metadata.created if metadata and metadata.created is not None else now),
                    "X-Last-Modified": str(now),
                    "X-Permission": metadata.permission if metadata and metadata.permission else "rw",
                }
            )
        request = Request(self._url(space, page), data=body, method=method, headers=headers)
        try:
            return self._opener.open(request, timeout=REQUEST_TIMEOUT_SECONDS)
        except HTTPError as error:
            try:
                if error.code == 404:
                    raise MissingPageError(f"SilverBullet page not found: {page or '/.fs'}.") from error
                if 300 <= error.code < 400:
                    raise SilverBulletError(
                        f"SilverBullet rejected authentication with HTTP {error.code} redirect."
                    ) from error
                try:
                    detail = self._read_limited(error, 16 * 1024).decode("utf-8", errors="replace").strip()
                except Exception:  # noqa: BLE001 - never let error-body parsing mask the HTTP status.
                    detail = ""
                if token:
                    detail = detail.replace(token, "[REDACTED]")
                suffix = f": {detail}" if detail else ""
                raise SilverBulletError(f"SilverBullet {method} request failed with HTTP {error.code}{suffix}") from error
            finally:
                error.close()
        except (URLError, TimeoutError, OSError) as error:
            message = str(error).replace(token, "[REDACTED]")
            raise SilverBulletError(f"Could not reach SilverBullet: {message}") from error

    @staticmethod
    def _header_integer(headers, name: str) -> int | None:
        value = headers.get(name)
        if value is None:
            return None
        try:
            return int(value)
        except ValueError:
            return None

    def _metadata(self, headers, size: int) -> Metadata:
        return Metadata(
            created=self._header_integer(headers, "X-Created"),
            last_modified=self._header_integer(headers, "X-Last-Modified"),
            content_type=headers.get("X-Content-Type") or headers.get("Content-Type"),
            size=self._header_integer(headers, "X-Content-Length") or size,
            permission=headers.get("X-Permission"),
            etag=headers.get("ETag"),
        )

    def _assert_allowed(self, space: Space, page: str, write: bool = False) -> None:
        prefixes = space.write_prefixes if write else space.read_prefixes
        if not _path_allowed(page, prefixes):
            operation = "write" if write else "read"
            raise SilverBulletError(f"SilverBullet {operation} path is outside the configured allowlist: {page}.")
        if write and is_system_path(page):
            raise SilverBulletError(f"SilverBullet managed path is read-only: {page}.")

    def list_files(self, space: Space, include_system: bool = False) -> list[dict[str, Any]]:
        with self._request(space, "GET") as response:
            raw = self._read_limited(response, HARD_MAX_LIST_BYTES)
        try:
            parsed = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise SilverBulletError("SilverBullet file listing is not valid JSON.") from error
        if not isinstance(parsed, list):
            raise SilverBulletError("SilverBullet file listing has an unexpected shape.")
        files: list[dict[str, Any]] = []
        for item in parsed:
            if not isinstance(item, dict) or not isinstance(item.get("name"), str):
                continue
            try:
                page = normalize_page(item["name"])
            except SilverBulletError:
                continue
            if page != item["name"] or not _path_allowed(page, space.read_prefixes):
                continue
            if not include_system and is_system_path(page):
                continue
            entry = {key: item.get(key) for key in ("name", "created", "lastModified", "contentType", "size", "perm")}
            files.append(entry)
        files.sort(key=lambda item: item["name"].casefold())
        return files

    def read_page(self, space: Space, page: str) -> Snapshot:
        self._assert_allowed(space, page)
        with self._request(space, "GET", page) as response:
            body = self._read_limited(response, self.config.max_content_bytes)
            metadata = self._metadata(response.headers, len(body))
        try:
            content = body.decode("utf-8")
        except UnicodeDecodeError as error:
            raise SilverBulletError(f"SilverBullet page is not valid UTF-8 text: {page}.") from error
        return Snapshot(page=page, content=content, body=body, metadata=metadata)

    @staticmethod
    def _assert_version(snapshot: Snapshot, expected: Any) -> None:
        if isinstance(expected, bool) or not isinstance(expected, int):
            raise SilverBulletError("expected_last_modified must be the integer returned by silverbullet_read.")
        actual = snapshot.metadata.last_modified
        if actual is None:
            raise ConflictError(f"SilverBullet did not provide lastModified for {snapshot.page}; refusing an unsafe write.")
        if actual != expected:
            raise ConflictError(
                f"SilverBullet conflict for {snapshot.page}: expected lastModified {expected}, current value is {actual}. "
                "Read the page again and reconcile the changes."
            )

    def _put(self, space: Space, page: str, content: str, metadata: Metadata | None = None) -> Snapshot:
        self._assert_allowed(space, page, write=True)
        body = content.encode("utf-8")
        if len(body) > self.config.max_content_bytes:
            raise SilverBulletError(f"SilverBullet content exceeds the {self.config.max_content_bytes}-byte write limit.")
        with self._request(space, "PUT", page, body=body, metadata=metadata) as response:
            self._read_limited(response, 16 * 1024)
        verified = self.read_page(space, page)
        if verified.body != body:
            raise SilverBulletError(f"SilverBullet write verification failed for {page}.")
        return verified

    def _delete(self, space: Space, page: str, metadata: Metadata) -> None:
        with self._request(space, "DELETE", page, metadata=metadata) as response:
            self._read_limited(response, 16 * 1024)

    def create(self, space: Space, page: str, content: str) -> Snapshot:
        with self._mutation_lock:
            self._assert_allowed(space, page, write=True)
            try:
                self.read_page(space, page)
            except MissingPageError:
                return self._put(space, page, content)
            raise SilverBulletError(f"SilverBullet page already exists: {page}.")

    def update(self, space: Space, page: str, content: str, expected_last_modified: Any) -> Snapshot:
        with self._mutation_lock:
            current = self.read_page(space, page)
            self._assert_allowed(space, page, write=True)
            if current.metadata.permission == "ro":
                raise SilverBulletError(f"SilverBullet page is read-only: {page}.")
            self._assert_version(current, expected_last_modified)
            return self._put(space, page, content, current.metadata)

    def append(self, space: Space, page: str, content: str, expected_last_modified: Any = None) -> tuple[Snapshot, bool]:
        with self._mutation_lock:
            try:
                current = self.read_page(space, page)
            except MissingPageError:
                return self._put(space, page, content), True
            self._assert_allowed(space, page, write=True)
            if current.metadata.permission == "ro":
                raise SilverBulletError(f"SilverBullet page is read-only: {page}.")
            if expected_last_modified is None:
                raise ConflictError(
                    f"{page} already exists; read it first and pass its last_modified as expected_last_modified."
                )
            self._assert_version(current, expected_last_modified)
            separator = "" if not current.content or current.content.endswith("\n") or content.startswith("\n") else "\n"
            return self._put(space, page, f"{current.content}{separator}{content}", current.metadata), False

    def _move_locked(
        self,
        space: Space,
        source: str,
        destination: str,
        expected_last_modified: Any,
    ) -> Snapshot:
        if source == destination:
            raise SilverBulletError("SilverBullet source and destination must differ.")
        current = self.read_page(space, source)
        self._assert_allowed(space, source, write=True)
        self._assert_allowed(space, destination, write=True)
        if current.metadata.permission == "ro":
            raise SilverBulletError(f"SilverBullet page is read-only: {source}.")
        self._assert_version(current, expected_last_modified)
        try:
            self.read_page(space, destination)
        except MissingPageError:
            pass
        else:
            raise SilverBulletError(f"SilverBullet destination already exists: {destination}.")

        copied = self._put(space, destination, current.content, current.metadata)
        latest = self.read_page(space, source)
        try:
            self._assert_version(latest, expected_last_modified)
        except ConflictError as error:
            raise ConflictError(
                f"{error} The destination copy {destination} was verified, but the changed source was retained."
            ) from error
        self._delete(space, source, latest.metadata)
        return copied

    def move(self, space: Space, source: str, destination: str, expected_last_modified: Any) -> Snapshot:
        with self._mutation_lock:
            return self._move_locked(space, source, destination, expected_last_modified)

    def soft_delete(
        self,
        space: Space,
        page: str,
        expected_last_modified: Any,
        permanent: bool = False,
    ) -> tuple[str | None, int]:
        with self._mutation_lock:
            current = self.read_page(space, page)
            self._assert_allowed(space, page, write=True)
            if current.metadata.permission == "ro":
                raise SilverBulletError(f"SilverBullet page is read-only: {page}.")
            self._assert_version(current, expected_last_modified)
            if permanent:
                self._delete(space, page, current.metadata)
                return None, len(current.body)
            if page.casefold().startswith("trash/"):
                raise SilverBulletError("Page is already in Trash; permanent deletion requires permanent=true.")
            destination = f"Trash/{page}"
            try:
                self.read_page(space, destination)
            except MissingPageError:
                pass
            else:
                stem, dot, suffix = destination.rpartition(".")
                stamp = int(time.time() * 1000)
                destination = f"{stem}--{stamp}.{suffix}" if dot else f"{destination}--{stamp}"
            copied = self._move_locked(space, page, destination, expected_last_modified)
            return copied.page, len(current.body)


def metadata_dict(metadata: Metadata) -> dict[str, Any]:
    return asdict(metadata)

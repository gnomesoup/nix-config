"""Model-facing schemas for the Inigo SilverBullet tools."""

SPACE = {
    "type": "string",
    "description": "Configured SilverBullet space name. Omit to use the default space.",
}
PAGE = {
    "type": "string",
    "description": "Space-relative page path. A .md extension is added when absent.",
}
EXPECTED_VERSION = {
    "type": "integer",
    "description": (
        "Exact last_modified value from the most recent silverbullet_read. "
        "The write is refused if the page changed since that read."
    ),
}


def schema(name, description, properties, required=None):
    return {
        "name": name,
        "description": description,
        "parameters": {
            "type": "object",
            "properties": properties,
            "required": required or [],
            "additionalProperties": False,
        },
    }


LIST_PAGES = schema(
    "silverbullet_list_pages",
    "List allowed SilverBullet pages and metadata. Managed pages are excluded unless include_system is true.",
    {
        "space": SPACE,
        "prefix": {"type": "string", "description": "Optional relative path prefix."},
        "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 50},
        "include_system": {
            "type": "boolean",
            "default": False,
            "description": "Include Library, Repositories, and dot-prefixed managed paths.",
        },
    },
)

SEARCH = schema(
    "silverbullet_search",
    "Search allowed SilverBullet text pages client-side for literal, case-insensitive path and line matches.",
    {
        "space": SPACE,
        "query": {"type": "string", "minLength": 1, "description": "Literal text to find."},
        "prefix": {"type": "string", "description": "Optional relative path prefix to scan."},
        "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 50},
        "include_system": {
            "type": "boolean",
            "default": False,
            "description": "Include managed paths in the search.",
        },
    },
    ["query"],
)

READ = schema(
    "silverbullet_read",
    "Read an allowed SilverBullet text page and return content, metadata, and the last_modified conflict token.",
    {
        "space": SPACE,
        "page": PAGE,
        "start_line": {"type": "integer", "minimum": 1, "default": 1},
        "max_lines": {"type": "integer", "minimum": 1, "maximum": 2000},
    },
    ["page"],
)

CREATE = schema(
    "silverbullet_create",
    "Create a new allowed SilverBullet Markdown page without overwriting an existing page, then verify the write.",
    {
        "space": SPACE,
        "page": PAGE,
        "content": {"type": "string", "minLength": 1, "description": "Complete Markdown content."},
    },
    ["page", "content"],
)

UPDATE = schema(
    "silverbullet_update",
    "Replace an existing allowed SilverBullet page only if its last_modified value still matches a prior read.",
    {
        "space": SPACE,
        "page": PAGE,
        "content": {"type": "string", "description": "Complete replacement content."},
        "expected_last_modified": EXPECTED_VERSION,
    },
    ["page", "content", "expected_last_modified"],
)

APPEND = schema(
    "silverbullet_append",
    (
        "Append Markdown to an allowed SilverBullet page, or create it when absent. "
        "An existing page requires expected_last_modified from a prior read."
    ),
    {
        "space": SPACE,
        "page": PAGE,
        "content": {"type": "string", "minLength": 1, "description": "Markdown content to append."},
        "expected_last_modified": EXPECTED_VERSION,
    },
    ["page", "content"],
)

MOVE = schema(
    "silverbullet_move",
    "Move an allowed SilverBullet page without overwriting the destination, guarded by the source last_modified value.",
    {
        "space": SPACE,
        "source": PAGE,
        "destination": PAGE,
        "expected_last_modified": EXPECTED_VERSION,
    },
    ["source", "destination", "expected_last_modified"],
)

SOFT_DELETE = schema(
    "silverbullet_soft_delete",
    (
        "Move an allowed page into Trash/ before deleting the source. Set permanent=true only when the user "
        "explicitly requests irreversible deletion; this bypasses Trash."
    ),
    {
        "space": SPACE,
        "page": PAGE,
        "expected_last_modified": EXPECTED_VERSION,
        "permanent": {
            "type": "boolean",
            "default": False,
            "description": "Irreversibly delete instead of moving to Trash; requires an explicit user request.",
        },
    },
    ["page", "expected_last_modified"],
)

ALL = [LIST_PAGES, SEARCH, READ, CREATE, UPDATE, APPEND, MOVE, SOFT_DELETE]

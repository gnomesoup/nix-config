"""Pure identity checks shared by the host tests and Zulip-side program."""
# The root organization has an empty slug; "mmjo" is only its display name.
REALM_ID = ""
REALM_URL = "https://chat.mmjo.com"
OWNER_EMAIL = "michael@mmjo.com"
BOT_EMAIL = "inigo-bot@chat.mmjo.com"
BOT_NAME = "Inigo"


def decide(realm, owner, bot):
    """Return the operation; never modify a preexisting account."""
    if (realm != {"string_id": REALM_ID, "url": REALM_URL, "deactivated": False}
            or realm.get("deactivated") is not False):
        raise ValueError("realm identity mismatch")
    if (not owner or type(owner.get("id")) is not int or owner["id"] <= 0
            or owner.get("delivery_email", "").lower() != OWNER_EMAIL
            or owner.get("is_active") is not True or owner.get("is_bot") is not False
            or owner.get("role") not in (100, 200, 300, 400)):
        raise ValueError("owner identity mismatch")
    if bot is None:
        return "created"
    expected = {
        "email": BOT_EMAIL, "delivery_email": BOT_EMAIL, "full_name": BOT_NAME,
        "is_active": True, "is_bot": True, "bot_type": 1,
        "bot_owner_id": owner["id"], "role": 400, "is_staff": False,
        "can_forge_sender": False, "can_create_users": False,
        "can_change_user_emails": False,
    }
    if (type(bot.get("id")) is not int or bot["id"] <= 0
            or any(type(bot.get(key)) is not type(value) or bot.get(key) != value
                   for key, value in expected.items())):
        raise ValueError("existing account identity mismatch")
    return "existing"

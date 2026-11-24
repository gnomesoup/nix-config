"""Executed only inside the pinned Zulip 11.6 application shell.

policy.py is prepended by the host. No settings/secrets are printed.
"""
import contextlib
import json
import os


def provision_in_zulip():
    from email.headerregistry import Address
    from django.db import transaction
    from django.db.models import Q
    from version import ZULIP_VERSION_WITHOUT_COMMIT
    from zerver.actions.create_user import do_create_user, notify_created_bot
    from zerver.lib.users import (
        check_bot_name_available, check_can_create_bot, check_valid_bot_type,
    )
    from zerver.models import Realm, UserProfile

    if ZULIP_VERSION_WITHOUT_COMMIT != "11.6":
        raise ValueError("unreviewed Zulip version")
    bot_fields = (
        "id", "email", "delivery_email", "full_name", "is_active", "is_bot",
        "bot_type", "bot_owner_id", "role", "is_staff", "can_forge_sender",
        "can_create_users", "can_change_user_emails",
    )
    # Serialize this operation, including different root invocations, on the realm.
    with transaction.atomic():
        realm = Realm.objects.select_for_update().get(string_id=REALM_ID)
        realm_data = {"string_id": realm.string_id, "url": realm.url,
                      "deactivated": realm.deactivated}
        owner = UserProfile.objects.select_for_update().get(
            realm=realm, delivery_email__iexact=OWNER_EMAIL,
        )
        owner_data = {name: getattr(owner, name) for name in (
            "id", "delivery_email", "is_active", "is_bot", "role",
        )}
        # Match the server API's short_name + '-bot' convention and bot domain.
        email = Address(username="inigo-bot", domain=realm.get_bot_domain()).addr_spec
        if email != BOT_EMAIL:
            raise ValueError("unexpected bot domain")
        candidates = UserProfile.objects.select_for_update().filter(realm=realm).filter(
            Q(email__iexact=email) | Q(delivery_email__iexact=email),
        )
        matches = list(candidates)
        if len(matches) > 1:
            raise ValueError("ambiguous bot identity")
        bot = matches[0] if matches else None
        bot_data = None if bot is None else {name: getattr(bot, name) for name in bot_fields}
        status = decide(realm_data, owner_data, bot_data)
        if status == "created":
            # These are the permission/name checks in Zulip 11.6's add_bot_backend.
            check_bot_name_available(realm_id=realm.id, full_name=BOT_NAME, is_activation=False)
            check_can_create_bot(owner, UserProfile.DEFAULT_BOT)
            check_valid_bot_type(owner, UserProfile.DEFAULT_BOT)
            bot = do_create_user(
                email=email, password=None, realm=realm, full_name=BOT_NAME,
                bot_type=UserProfile.DEFAULT_BOT, role=UserProfile.ROLE_MEMBER,
                bot_owner=owner, acting_user=owner, default_all_public_streams=False,
                default_sending_stream=None, default_events_register_stream=None,
            )
            notify_created_bot(bot)
        # Read back the exact database target, including the newly created account.
        bot = UserProfile.objects.get(id=bot.id, realm=realm)
        decide(realm_data, owner_data, {name: getattr(bot, name) for name in bot_fields})
        result = {
            "status": status, "realm": realm.string_id, "site": realm.url,
            "bot_email": bot.delivery_email, "user_id": bot.id,
            "owner_email": OWNER_EMAIL, "api_key": bot.api_key,
        }
    return result


def run_container():
    # Never relay app logging, exceptions, ORM representations, or tracebacks.
    with open(os.devnull, "w") as sink:
        try:
            with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
                result = provision_in_zulip()
        except Exception:
            result = {"error": "Zulip provisioning failed; check realm, owner and bot identity"}
    print(json.dumps(result, separators=(",", ":")))


run_container()

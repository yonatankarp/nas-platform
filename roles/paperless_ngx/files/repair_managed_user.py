"""Repair a managed user's non-secret properties after proving its identity.

Run inside the Paperless webserver container by `manage.py shell -c`. Inputs
arrive as environment variables.

Deliberately never touches the password: this path runs against accounts that
already exist, and a repair that reset credentials would silently revoke a
working login. The identity binding is re-proven here rather than trusted from
the earlier check, because this transaction is the one that writes.

Group names are resolved as a set and the count is asserted, so a missing group
fails the play instead of silently narrowing the user's access.
"""

import json
import os

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import transaction
from rest_framework.authtoken.models import Token

with transaction.atomic():
    expected_id = int(os.environ["MANAGED_ID"])
    expected_username = os.environ["MANAGED_USERNAME"].strip().casefold()
    token = Token.objects.select_related("user").select_for_update().get(
        key=os.environ["MANAGED_TOKEN"]
    )
    user = get_user_model().objects.select_for_update().get(pk=expected_id)
    assert (
        token.user_id == expected_id
        and user.username.strip().casefold() == expected_username
    ), "managed identity binding invalid"
    names = json.loads(os.environ["MANAGED_GROUPS"])
    groups = list(Group.objects.filter(name__in=names))
    assert len(groups) == len(names), "managed group contract invalid"
    user.email = os.environ["MANAGED_EMAIL"]
    user.is_active = os.environ["MANAGED_ACTIVE"] == "true"
    user.is_staff = os.environ["MANAGED_STAFF"] == "true"
    user.is_superuser = os.environ["MANAGED_SUPERUSER"] == "true"
    user.save(update_fields=["email", "is_active", "is_staff", "is_superuser"])
    user.groups.set(groups)

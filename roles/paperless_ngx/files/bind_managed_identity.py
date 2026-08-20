"""Prove an authenticated token belongs to the expected managed user.

Run inside the Paperless webserver container by `manage.py shell -c`. Inputs
arrive as environment variables.

This runs before any repair writes to the row. Both the token owner and the
username must match what the play authenticated, and the rows are locked with
`select_for_update` inside the transaction, so a concurrent rename cannot make a
later repair land on a different account than the one whose credential was
proven. Usernames are compared case-folded because Paperless treats them
case-insensitively at login.
"""

import os

from django.contrib.auth import get_user_model
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

"""Prove an authenticated token belongs to the expected managed user.

Rows are locked with `select_for_update` so a concurrent rename cannot redirect
a later repair; usernames compare case-folded, as Paperless logins do.
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

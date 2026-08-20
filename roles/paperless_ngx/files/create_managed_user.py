"""Create one absent Paperless managed user with its initial password.

Run inside the Paperless webserver container by `manage.py shell -c`. Inputs
arrive as environment variables so no vault value is interpolated into this
source or into argv.

Identity and password are persisted in a single transaction on purpose: a user
row that exists without its password set is a login-less account that the next
converge would treat as already present, so the two must commit together or not
at all.
"""

import os

from django.contrib.auth import get_user_model
from django.db import transaction

with transaction.atomic():
    user = get_user_model().objects.create(
        username=os.environ["MANAGED_USERNAME"],
        email=os.environ["MANAGED_EMAIL"],
    )
    user.set_password(os.environ["MANAGED_PASSWORD"])
    user.save()

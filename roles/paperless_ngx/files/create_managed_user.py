"""Create one absent Paperless managed user with its initial password.

Identity and password commit in one transaction: a row without a password is a
login-less account the next converge would treat as present.
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

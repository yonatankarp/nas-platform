"""Restore the vault Paperless administrator's mail address and privileges.

`get` fails unless exactly one row matches; the password is never touched.
"""

import os

from django.contrib.auth import get_user_model

user = get_user_model().objects.get(username=os.environ["MANAGED_USERNAME"])
user.email = os.environ["MANAGED_EMAIL"]
user.is_active = True
user.is_staff = True
user.is_superuser = True
user.save(update_fields=["email", "is_active", "is_staff", "is_superuser"])

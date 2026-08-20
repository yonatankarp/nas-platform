"""Restore the vault Paperless administrator's mail address and privileges.

Run inside the Paperless webserver container by `manage.py shell -c`. Inputs
arrive in MANAGED_USERNAME and MANAGED_EMAIL so no vault value reaches the
command line.

Uses `get` rather than `filter().first()`: the caller only invokes this after its
inspection reported exactly one match, so more or fewer rows here means the state
changed underneath and the play should fail rather than guess. The password is
deliberately untouched, so repairing privileges never revokes a working login.
"""

import os

from django.contrib.auth import get_user_model

user = get_user_model().objects.get(username=os.environ["MANAGED_USERNAME"])
user.email = os.environ["MANAGED_EMAIL"]
user.is_active = True
user.is_staff = True
user.is_superuser = True
user.save(update_fields=["email", "is_active", "is_staff", "is_superuser"])

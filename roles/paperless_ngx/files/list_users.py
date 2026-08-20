"""Emit every Paperless user as sorted JSON on stdout.

Run inside the Paperless webserver container by `manage.py shell -c`, so Django
is already configured and the imports resolve against the app's environment.

The listing is read twice per converge, before and after managed-user
reconciliation, and both callers parse the last stdout line as JSON. Keys are
sorted so an unchanged user set produces byte-identical output and the play stays
idempotent.
"""

import json

from django.contrib.auth import get_user_model

users = [
    {
        "id": user.pk,
        "username": user.username,
        "email": user.email,
        "is_active": user.is_active,
        "is_staff": user.is_staff,
        "is_superuser": user.is_superuser,
        "groups": sorted(user.groups.values_list("name", flat=True)),
    }
    for user in get_user_model().objects.all()
]
print(json.dumps(users, sort_keys=True))

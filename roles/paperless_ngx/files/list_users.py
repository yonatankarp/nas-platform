"""Emit every Paperless user as sorted JSON, byte-stable for idempotence."""

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

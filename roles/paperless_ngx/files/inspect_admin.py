"""Report the vault Paperless administrator's identity and match count as JSON."""

import json
import os

from django.contrib.auth import get_user_model

users = get_user_model().objects.filter(username=os.environ["MANAGED_USERNAME"])
user = users.first()
print(
    json.dumps(
        {
            "count": users.count(),
            "email": user.email if user else "",
            "is_active": user.is_active if user else False,
            "is_staff": user.is_staff if user else False,
            "is_superuser": user.is_superuser if user else False,
        }
    )
)

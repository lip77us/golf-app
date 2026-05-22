"""
accounts/views.py
-----------------
Account-member management API.

Endpoints (all under /api/account/):
  GET    members/         List members of the caller's account.
  POST   members/         Create a new member (admin only).
  GET    members/<id>/    Retrieve one member (admin OR self).
  PATCH  members/<id>/    Update one member (admin only).
  DELETE members/<id>/    Remove one member (admin only, never self).

Authorization
-------------
* Listing the roster is open to any account member — golfers want
  to see who else is in their group.
* Mutations (create / update / delete) require is_account_admin.
* `last admin guard` — an admin may not demote themselves or
  delete themselves if doing so would leave the account with zero
  admins.  Without this, a one-admin account could lock itself out
  permanently with a single tap.
"""

from __future__ import annotations

from django.contrib.auth import get_user_model
from rest_framework import status
from rest_framework.exceptions import PermissionDenied
from rest_framework.response import Response
from rest_framework.views import APIView

from .scoping import IsAccountAdmin, IsAccountMember, account_get_or_404
from .serializers import (
    MemberCreateSerializer,
    MemberSerializer,
    MemberUpdateSerializer,
)


User = get_user_model()


def _other_admins_qs(account, exclude_user_id: int):
    """Other is_account_admin users in `account`, excluding one id."""
    return User.objects.filter(
        account=account,
        is_account_admin=True,
        is_active=True,
    ).exclude(pk=exclude_user_id)


class MemberListView(APIView):
    """GET (any member) / POST (admins only) /api/account/members/."""

    def get_permissions(self):
        return [IsAccountAdmin() if self.request.method == 'POST'
                else IsAccountMember()]

    def get(self, request):
        members = (
            User.objects
            .filter(account=request.user.account)
            .order_by('username')
        )
        return Response(MemberSerializer(members, many=True).data)

    def post(self, request):
        ser = MemberCreateSerializer(
            data=request.data,
            context={'account': request.user.account, 'request': request},
        )
        ser.is_valid(raise_exception=True)
        user = ser.save()
        return Response(
            MemberSerializer(user).data,
            status=status.HTTP_201_CREATED,
        )


class MemberDetailView(APIView):
    """GET / PATCH / DELETE /api/account/members/<id>/."""

    def get_permissions(self):
        # Self-read is allowed for any member; everything else needs admin.
        if self.request.method == 'GET':
            return [IsAccountMember()]
        return [IsAccountAdmin()]

    def get(self, request, pk: int):
        # Same-account scoping via account_get_or_404 so trying to
        # GET a member of a different tenant returns 404, not 403.
        user = account_get_or_404(User, request.user.account, pk=pk)
        # Non-admins can only read themselves, not other members.
        if not request.user.is_account_admin and request.user.pk != user.pk:
            raise PermissionDenied(
                'Only account admins can view other members.',
            )
        return Response(MemberSerializer(user).data)

    def patch(self, request, pk: int):
        user = account_get_or_404(User, request.user.account, pk=pk)

        # Last-admin guard for is_account_admin demotion of self.
        will_demote_self = (
            user.pk == request.user.pk
            and request.data.get('is_account_admin') is False
        )
        if will_demote_self and not _other_admins_qs(
            request.user.account, user.pk,
        ).exists():
            return Response(
                {'detail': 'You are the only admin in this account.  '
                           'Promote another member before demoting '
                           'yourself.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        ser = MemberUpdateSerializer(user, data=request.data, partial=True)
        ser.is_valid(raise_exception=True)
        user = ser.save()
        return Response(MemberSerializer(user).data)

    def delete(self, request, pk: int):
        user = account_get_or_404(User, request.user.account, pk=pk)

        # Cannot delete yourself outright — even a sole admin can't
        # remove the only seat in the account.  Self-departure should
        # be a separate flow (transfer admin first, then delete).
        if user.pk == request.user.pk:
            return Response(
                {'detail': 'You cannot delete your own user.  Promote '
                           'another admin and have them remove you, '
                           'or contact support to close the account.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Last-admin guard for deleting another admin.
        if user.is_account_admin and not _other_admins_qs(
            request.user.account, user.pk,
        ).exists():
            return Response(
                {'detail': 'Cannot remove the only admin in this '
                           'account.  Promote another member first.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        user.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)

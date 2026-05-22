"""
accounts/serializers.py
-----------------------
DRF serializers for the account-member management endpoints.

Admins of an Account use these to add / list / update / remove the
users inside their tenant.  No cross-account references — every
serializer reads/writes `account` from the request and never accepts
it as a client-supplied value.
"""

from django.contrib.auth import get_user_model
from rest_framework import serializers


User = get_user_model()


class MemberSerializer(serializers.ModelSerializer):
    """Read view: what GETs return for an Account member."""

    has_player_profile = serializers.SerializerMethodField()

    class Meta:
        model  = User
        fields = (
            'id', 'username', 'email', 'first_name', 'last_name',
            'is_account_admin', 'is_active', 'date_joined', 'last_login',
            'has_player_profile',
        )
        read_only_fields = (
            'id', 'username', 'date_joined', 'last_login',
            'has_player_profile',
        )

    def get_has_player_profile(self, user) -> bool:
        # OneToOne reverse-access raises Player.DoesNotExist when
        # there's no linked profile; cheaper to ask the cached
        # `_state` than to try/except for every row.
        try:
            return user.player_profile is not None
        except Exception:
            return False


class MemberCreateSerializer(serializers.ModelSerializer):
    """
    POST body for creating a new member inside the caller's account.
    `account` is injected by the view from `request.user.account` —
    not accepted from the client to avoid cross-tenant leakage.
    """

    password = serializers.CharField(write_only=True, min_length=8,
                                     style={'input_type': 'password'})

    class Meta:
        model  = User
        fields = (
            'username', 'password', 'email',
            'first_name', 'last_name', 'is_account_admin',
        )

    def validate_username(self, value: str) -> str:
        value = value.strip()
        if not value:
            raise serializers.ValidationError('Username is required.')
        account = self.context['account']
        # CI lookup matches the (Lower(username), account) constraint.
        if User.objects.filter(
            account=account, username__iexact=value,
        ).exists():
            raise serializers.ValidationError(
                f'A user named "{value}" already exists in this account.'
            )
        return value

    def create(self, validated_data):
        account = self.context['account']
        password = validated_data.pop('password')
        is_admin = validated_data.pop('is_account_admin', False)
        user = User.objects.create_user(
            account=account,
            password=password,
            **validated_data,
        )
        if is_admin:
            user.is_account_admin = True
            user.save(update_fields=['is_account_admin'])
        return user


class MemberUpdateSerializer(serializers.ModelSerializer):
    """
    PATCH body for editing a member.  Username and account are
    immutable — to rename a user, delete and recreate.  Password may
    optionally be reset by passing `password`; omitting it leaves
    the existing hash alone.
    """

    password = serializers.CharField(write_only=True, required=False,
                                     min_length=8,
                                     style={'input_type': 'password'})

    class Meta:
        model  = User
        fields = (
            'email', 'first_name', 'last_name',
            'is_account_admin', 'is_active', 'password',
        )

    def update(self, instance, validated_data):
        password = validated_data.pop('password', None)
        for field, value in validated_data.items():
            setattr(instance, field, value)
        if password:
            instance.set_password(password)
        instance.save()
        return instance

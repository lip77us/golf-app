"""
accounts/admin.py — register Account + custom User in Django admin.

Reuses Django's stock UserAdmin so the change-password flow, the
groups/permissions tabs, and the search-by-username behavior all keep
working.  We just slot in `account` and `is_account_admin` as new
fields and extend the columns / filters / fieldsets.
"""

from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin

from .admin_forms import AccountAdminAuthenticationForm
from .models import Account, User


# Replace the stock admin login form with the account-aware one so
# /admin/login/ can authenticate users now that usernames are non-unique
# globally (AccountBackend is the only backend, and it needs
# account_name to disambiguate).  The matching template lives at
# templates/admin/login.html — it inserts the account_name row above
# the existing username row.
admin.site.login_form = AccountAdminAuthenticationForm


@admin.register(Account)
class AccountAdmin(admin.ModelAdmin):
    list_display  = ('id', 'name', 'created_at', 'member_count')
    search_fields = ('name',)
    ordering      = ('name',)
    readonly_fields = ('created_at',)

    @admin.display(description='Members')
    def member_count(self, obj):
        return obj.members.count()


@admin.register(User)
class UserAdmin(BaseUserAdmin):
    """
    Same as Django's UserAdmin, plus columns/filters for Account and
    is_account_admin, and an extra fieldset to edit them.
    """
    list_display = (
        'username', 'account', 'is_account_admin',
        'email', 'first_name', 'last_name', 'is_staff',
    )
    list_filter = (
        'account', 'is_account_admin',
        'is_staff', 'is_superuser', 'is_active', 'groups',
    )
    search_fields = ('username', 'email', 'first_name', 'last_name',
                     'account__name')

    # Insert "Account" fieldset between the standard "Personal info"
    # and "Permissions" sections.
    fieldsets = (
        (None, {'fields': ('username', 'password')}),
        ('Personal info', {'fields': ('first_name', 'last_name', 'email')}),
        ('Account', {'fields': ('account', 'is_account_admin')}),
        ('Permissions', {'fields': (
            'is_active', 'is_staff', 'is_superuser',
            'groups', 'user_permissions',
        )}),
        ('Important dates', {'fields': ('last_login', 'date_joined')}),
    )
    add_fieldsets = (
        (None, {
            'classes': ('wide',),
            'fields': ('username', 'account', 'password1', 'password2'),
        }),
    )

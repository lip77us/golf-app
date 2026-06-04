"""
accounts/admin_forms.py
-----------------------
Account-aware admin forms.

Phase 3 dropped ModelBackend in favour of AccountBackend, which means
the stock Django admin login form (username + password only) can no
longer find users — two "paul"s might exist in two different
accounts.  This form layers an `Account` text field on top of the
standard admin form and passes its value through to authenticate()
as the `account_name` kwarg AccountBackend expects.

It also provides AccountUserCreationForm — the admin "add user" form —
because Django's stock UserCreationForm.clean_username enforces GLOBAL
username uniqueness, which is wrong for our per-account model (two
accounts may each have a "paul").

Both are wired in at `accounts/admin.py`.
"""

from django import forms
from django.contrib.admin.forms import AdminAuthenticationForm
from django.contrib.auth import authenticate
from django.utils.translation import gettext_lazy as _

# AdminUserCreationForm (Django 5.1+) is the admin's default "add user" form;
# fall back to UserCreationForm on older Django.  Both inherit a GLOBAL
# clean_username from UserCreationForm, which we override below.
try:
    from django.contrib.auth.forms import AdminUserCreationForm as _BaseAddForm
except ImportError:  # pragma: no cover - older Django
    from django.contrib.auth.forms import UserCreationForm as _BaseAddForm

from .models import User


class AccountAdminAuthenticationForm(AdminAuthenticationForm):
    """
    /admin/login/ form — same fields as Django's stock admin form,
    plus a leading "Account" text field.
    """

    account_name = forms.CharField(
        label=_('Account'),
        max_length=80,
        widget=forms.TextInput(attrs={
            'autofocus': True,
            'autocapitalize': 'none',
            'autocomplete': 'organization',
        }),
        help_text=_('Your club / group / family name.'),
    )

    def __init__(self, request=None, *args, **kwargs):
        super().__init__(request, *args, **kwargs)
        # AuthenticationForm declares `username` with autofocus=True;
        # account_name should grab the focus first, so strip the
        # username autofocus and re-order fields to put account_name
        # at the top.
        self.fields['username'].widget.attrs.pop('autofocus', None)
        # Move account_name to the front of the OrderedDict.
        ordering = ['account_name', 'username', 'password']
        self.fields = {k: self.fields[k] for k in ordering
                       if k in self.fields}

    def clean(self):
        account_name = (self.cleaned_data.get('account_name') or '').strip()
        username     = self.cleaned_data.get('username')
        password     = self.cleaned_data.get('password')

        if not (account_name and username and password):
            # Let the field-level required validators surface their
            # own errors; we only authenticate when all three fields
            # are populated.
            return self.cleaned_data

        self.user_cache = authenticate(
            self.request,
            account_name=account_name,
            username=username,
            password=password,
        )
        if self.user_cache is None:
            raise self.get_invalid_login_error()
        self.confirm_login_allowed(self.user_cache)
        return self.cleaned_data


class AccountUserCreationForm(_BaseAddForm):
    """
    Admin "add user" form with PER-ACCOUNT username uniqueness.

    Django's stock UserCreationForm.clean_username rejects any username
    that already exists in *any* account (a global, case-insensitive
    lookup).  That's wrong here: usernames are unique per account, so two
    accounts may each have a "paul".  We drop the global check and instead
    validate uniqueness within the chosen account (the model's
    (Lower(username), account) UniqueConstraint backs this up at the DB).
    """

    class Meta(_BaseAddForm.Meta):
        model  = User
        fields = ('username',)

    def clean_username(self):
        # Override the stock GLOBAL uniqueness check.  Per-account
        # uniqueness is enforced in clean() (account isn't cleaned yet at
        # this point, so we can't check it here).
        return self.cleaned_data.get('username')

    def clean(self):
        cleaned  = super().clean()
        username = cleaned.get('username')
        account  = cleaned.get('account')
        if username and account and User.objects.filter(
            account=account, username__iexact=username,
        ).exists():
            self.add_error(
                'username',
                _('A user with that username already exists in this account.'),
            )
        return cleaned

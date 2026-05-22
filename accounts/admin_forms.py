"""
accounts/admin_forms.py
-----------------------
Account-aware admin login form.

Phase 3 dropped ModelBackend in favour of AccountBackend, which means
the stock Django admin login form (username + password only) can no
longer find users — two "paul"s might exist in two different
accounts.  This form layers an `Account` text field on top of the
standard admin form and passes its value through to authenticate()
as the `account_name` kwarg AccountBackend expects.

The form is wired in at `accounts/admin.py` via
`admin.site.login_form = AccountAdminAuthenticationForm`.
"""

from django import forms
from django.contrib.admin.forms import AdminAuthenticationForm
from django.contrib.auth import authenticate
from django.utils.translation import gettext_lazy as _


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

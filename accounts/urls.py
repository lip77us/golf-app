"""
accounts/urls.py
----------------
URL patterns for the account-member management API.  Included from
api/urls.py under the /api/account/ prefix.
"""

from django.urls import path

from . import views


app_name = 'accounts'

urlpatterns = [
    path('members/',          views.MemberListView.as_view(),
         name='member-list'),
    path('members/<int:pk>/', views.MemberDetailView.as_view(),
         name='member-detail'),
]

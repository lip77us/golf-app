"""
URL configuration for my_golf_app project.

The `urlpatterns` list routes URLs to views. For more information please see:
    https://docs.djangoproject.com/en/6.0/topics/http/urls/
Examples:
Function views
    1. Add an import:  from my_app import views
    2. Add a URL to urlpatterns:  path('', views.home, name='home')
Class-based views
    1. Add an import:  from other_app.views import Home
    2. Add a URL to urlpatterns:  path('', Home.as_view(), name='home')
Including another URLconf
    1. Import the include() function: from django.urls import include, path
    2. Add a URL to urlpatterns:  path('blog/', include('blog.urls'))
"""
from django.contrib import admin
from django.urls import path, include

from api import watch_views
from api import invite_views

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/',   include('api.urls')),

    # Public spectator pages — token-gated, no auth, plain HTML.
    # Shared by the mobile app's "Share Watch Link" button.
    path('watch/<str:token>/', watch_views.watch_cup_round,
         name='watch-cup-round'),

    # Public invite landing page — shared by the in-app "Invite Friends" button.
    path('i/<str:code>/', invite_views.invite_landing, name='invite-landing'),
]

from django.apps import AppConfig


class CoreConfig(AppConfig):
    name = 'core'

    def ready(self):
        # Register model signals (new-game-suggestion notification).
        from . import signals  # noqa: F401

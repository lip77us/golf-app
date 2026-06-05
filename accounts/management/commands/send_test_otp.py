"""
send_test_otp — exercise the live OTP backend without creating any account.

Use this to confirm Twilio Verify (or the local console backend) is wired up
correctly on a server, end to end, before relying on the real login flow.

    # Send a code to your phone (uses the configured OTP_BACKEND):
    python manage.py send_test_otp +15551234567

    # Then check the code Twilio texted you:
    python manage.py send_test_otp +15551234567 --code 123456

Unlike the real /auth/otp/verify/ endpoint, this command never creates or logs
in a user — it only drives request_code / the backend's check, so it's safe to
run against production to validate credentials.
"""

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError

from accounts import otp as otp_service
from accounts.models import PhoneOTP
from accounts.phone import normalize


class Command(BaseCommand):
    help = "Send (and optionally check) a test OTP via the configured backend."

    def add_arguments(self, parser):
        parser.add_argument('phone', help='Recipient phone (any format; normalized to E.164).')
        parser.add_argument(
            '--code',
            help='If given, CHECK this code instead of sending a new one.',
        )

    def handle(self, *args, **opts):
        backend = getattr(settings, 'OTP_BACKEND', 'local')
        phone_in = opts['phone']
        code = opts.get('code')

        if code:
            # Check-only path — no account creation.
            norm = normalize(phone_in)
            if not norm:
                raise CommandError(f'Not a valid phone number: {phone_in!r}')
            if backend == 'twilio_verify':
                from accounts import twilio_verify
                ok = twilio_verify.check_verification(norm, code.strip())
            else:
                ok = PhoneOTP.check_code(norm, code.strip())
            self.stdout.write(
                self.style.SUCCESS(f'APPROVED ({norm})') if ok
                else self.style.ERROR(f'NOT approved / expired ({norm})')
            )
            return

        # Send path.
        try:
            norm, dev_code = otp_service.request_code(phone_in)
        except otp_service.OtpError as exc:
            raise CommandError(str(exc))

        self.stdout.write(self.style.SUCCESS(
            f'Sent via OTP_BACKEND={backend!r} to {norm}.'
        ))
        if dev_code:
            self.stdout.write(
                f'  Local/dev code (no real SMS on console backend): {dev_code}'
            )
        else:
            self.stdout.write(
                '  Twilio Verify sent the code by SMS; re-run with '
                '--code <code> to verify it.'
            )

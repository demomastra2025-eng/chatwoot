# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
Rails.application.config.filter_parameters += [
  :password, :secret, :_key, :auth, :crypt, :salt, :certificate, :otp, :access, :private, :protected, :ssn,
  :otp_secret, :otp_code, :backup_code, :mfa_token, :otp_backup_codes,
  :data, :base64, :qrcode, :media_data, :raw_payload,
  :api_hash, :string_session, :pending_phone_code_hash, :qr_login_url,
  # WebRTC SDP can include local network candidates/fingerprints and is too large/noisy for app logs.
  :sdp_answer, :sdp_offer,
  # Telegram notification binding uses profile access tokens inside incoming message text.
  :text,
  'pairingCode', 'pairing_code', 'disconnectionObject'
]

# Regex to filter all occurrences of 'token' in keys except for 'website_token'
filter_regex = /\A(?!.*\bwebsite_token\b).*token/i

# Apply the regex for filtering
Rails.application.config.filter_parameters += [filter_regex]

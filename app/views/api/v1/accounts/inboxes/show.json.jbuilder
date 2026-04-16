include_whatsapp_web_qr_code = true if !defined?(include_whatsapp_web_qr_code) || include_whatsapp_web_qr_code.nil?

json.partial! 'api/v1/models/inbox',
              formats: [:json],
              resource: @inbox,
              include_whatsapp_web_qr_code: include_whatsapp_web_qr_code

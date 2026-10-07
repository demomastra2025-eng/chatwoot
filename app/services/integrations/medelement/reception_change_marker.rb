class Integrations::Medelement::ReceptionChangeMarker
  FIELDS = %w[
    RECEPTION_CODE STARTTIME ENDTIME ACTIVE REMOVED PAID NOTIFY MARKER_CODE
    SPECIALIST_CODE COMPANY_CABINET_CODE SERVICES UPDATE_DATE UPDATED_AT UPDATE_DATETIME
  ].freeze

  def self.call(reception)
    return 'removed' if reception['REMOVED'].to_i == 1

    payload = reception.stringify_keys.slice(*FIELDS)
    payload['PATIENT_CODE'] = reception['PATIENT_CODE'].presence || reception['PROFILE_CODE']
    Digest::SHA256.hexdigest(payload.sort.to_h.to_json)
  end
end

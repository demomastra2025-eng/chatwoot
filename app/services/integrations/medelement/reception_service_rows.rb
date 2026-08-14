class Integrations::Medelement::ReceptionServiceRows
  DELETED_TYPE = ActiveModel::Type::Boolean.new
  ACTIVE_DATA_KEYS = %w[NOMENCLATURE_CODE PRICE QUANTITY TOTAL_SUM SUMMA].freeze
  InvalidSnapshotError = Class.new(StandardError)

  class << self
    def active(reception)
      service_rows(reception).reject { |row| DELETED_TYPE.cast(row['DELETED']) }
    end

    def identity_authoritative?(reception)
      reception.key?('SERVICES') && active(reception).all? { |row| row['NOMENCLATURE_CODE'].present? }
    end

    private

    def service_rows(reception)
      return [] unless reception.key?('SERVICES')

      rows = reception['SERVICES']
      raise InvalidSnapshotError, 'Medelement SERVICES must be an array of objects' unless rows.is_a?(Array) && rows.all?(Hash)
      return rows if rows.all? { |row| valid_row?(row) }

      raise InvalidSnapshotError, 'Active Medelement SERVICES rows must include provider service data'
    end

    def valid_row?(row)
      DELETED_TYPE.cast(row['DELETED']) || ACTIVE_DATA_KEYS.any? { |key| row[key].present? }
    end
  end
end

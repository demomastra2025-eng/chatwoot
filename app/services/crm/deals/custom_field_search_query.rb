class Crm::Deals::CustomFieldSearchQuery
  SQL = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1
      FROM jsonb_each(crm_deals.custom_attributes) AS custom_value(key, value)
      INNER JOIN crm_field_definitions
        ON crm_field_definitions.account_id = crm_deals.account_id
        AND crm_field_definitions.entity_kind = 'deal'
        AND crm_field_definitions.active = TRUE
        AND crm_field_definitions.key = custom_value.key
      WHERE
        (
          crm_field_definitions.label ILIKE :query
          AND custom_value.value <> 'null'::jsonb
          AND custom_value.value <> '""'::jsonb
          AND custom_value.value <> '[]'::jsonb
          AND (
            crm_field_definitions.field_type <> 'checkbox'
            OR custom_value.value = 'true'::jsonb
          )
        )
        OR (
          crm_field_definitions.field_type IN ('text', 'textarea', 'url')
          AND custom_value.value #>> '{}' ILIKE :query
        )
        OR (
          crm_field_definitions.field_type IN ('number', 'currency')
          AND (
            custom_value.value #>> '{}' ILIKE :query
            OR (:numeric_alias <> '' AND custom_value.value #>> '{}' = :numeric_alias)
          )
        )
        OR (
          crm_field_definitions.field_type = 'percent'
          AND (
            custom_value.value #>> '{}' ILIKE :query
            OR (:percent_alias <> '' AND custom_value.value #>> '{}' = :percent_alias)
          )
        )
        OR (
          crm_field_definitions.field_type = 'select'
          AND EXISTS (
            SELECT 1 FROM jsonb_array_elements(crm_field_definitions.options) AS field_option
            WHERE COALESCE(field_option->>'label', field_option #>> '{}') ILIKE :query
              AND COALESCE(field_option->>'value', field_option #>> '{}') = custom_value.value #>> '{}'
          )
        )
        OR (
          crm_field_definitions.field_type = 'multiselect'
          AND EXISTS (
            SELECT 1 FROM jsonb_array_elements(crm_field_definitions.options) AS field_option
            WHERE COALESCE(field_option->>'label', field_option #>> '{}') ILIKE :query
              AND custom_value.value ? COALESCE(field_option->>'value', field_option #>> '{}')
          )
        )
        OR (
          crm_field_definitions.field_type = 'checkbox'
          AND :checked_alias = TRUE
          AND custom_value.value = 'true'::jsonb
        )
        OR (
          crm_field_definitions.field_type = 'date'
          AND (
            custom_value.value #>> '{}' ILIKE :query
            OR (:date_alias <> '' AND custom_value.value #>> '{}' = :date_alias)
          )
        )
        OR (
          crm_field_definitions.field_type = 'datetime'
          AND (
            custom_value.value #>> '{}' ILIKE :query
            OR (
              :datetime_alias <> ''
              AND CASE
                WHEN custom_value.value #>> '{}' ~
                  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]+)?)?(Z|[+-][0-9]{2}:[0-9]{2})$'
                THEN DATE_TRUNC('minute', (custom_value.value #>> '{}')::timestamptz)
              END = DATE_TRUNC(
                'minute',
                CAST(NULLIF(:datetime_alias, '') AS timestamptz)
              )
            )
            OR (:datetime_alias = '' AND :date_alias <> '' AND custom_value.value #>> '{}' LIKE :date_alias_pattern)
          )
        )
    )
  SQL
end

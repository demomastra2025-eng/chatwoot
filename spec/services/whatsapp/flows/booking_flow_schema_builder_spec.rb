require 'rails_helper'

RSpec.describe Whatsapp::Flows::BookingFlowSchemaBuilder do
  def collect_string_references(node, prefix)
    pattern = /\A\$\{#{Regexp.escape(prefix)}\.([A-Za-z0-9_]+)\}\z/
    case node
    when String
      match = pattern.match(node)
      match ? [match[1]] : []
    when Array
      node.flat_map { |item| collect_string_references(item, prefix) }
    when Hash
      node.values.flat_map { |value| collect_string_references(value, prefix) }
    else
      []
    end
  end

  def collect_form_field_names(children)
    Array(children).select { |item| item.is_a?(Hash) }.filter_map do |component|
      name = component['name'].to_s
      type = component['type'].to_s
      name if name.present? && %w[Form Footer].exclude?(type)
    end
  end

  describe '#build' do
    %w[ru kk en].each do |locale|
      it "builds a valid Meta Flow JSON v6.0 routing model and screens for locale #{locale}" do
        schema = JSON.parse(described_class.new(locale: locale).to_json)

        expect(schema['version']).to eq('6.0')
        expect(schema['data_api_version']).to eq('3.0')
        expect(schema['routing_model']).to eq(
          'BOOKING_STEP' => ['SLOT_STEP'],
          'SLOT_STEP' => ['DETAILS_STEP'],
          'DETAILS_STEP' => []
        )
        expect(schema['screens'].map { |s| s['id'] }).to eq(%w[BOOKING_STEP SLOT_STEP DETAILS_STEP])
        expect(schema['screens'].last).to include('terminal' => true, 'success' => true)
      end

      it "binds only declared data and form fields on every screen for locale #{locale}" do
        schema = JSON.parse(described_class.new(locale: locale).to_json)
        field_types = %w[Dropdown TextInput TextArea]

        schema['screens'].each do |screen|
          declared_data_keys = screen.fetch('data').keys
          referenced_data_keys = collect_string_references(screen.fetch('layout'), 'data').uniq
          expect(referenced_data_keys - declared_data_keys).to be_empty

          form = screen.dig('layout', 'children').find { |child| child['type'] == 'Form' }
          declared_form_fields = collect_form_field_names(form['children'])
          expect(collect_string_references(form, 'form').uniq - declared_form_fields).to be_empty
          expect(form.fetch('init-values', {}).keys - declared_form_fields).to be_empty

          form['children'].each do |component|
            if field_types.include?(component['type'])
              expect(component['label'].length).to be <= 20
            elsif component['type'] == 'Footer'
              expect(component['label'].length).to be <= 35
            end
          end
        end
      end
    end

    it 'raises ArgumentError when custom labels exceed Meta Flow JSON v6.0 character limits' do
      expect { described_class.new(specialist_label: 'А' * 21) }.to raise_error(ArgumentError)
      expect { described_class.new(service_label: 'Б' * 21) }.to raise_error(ArgumentError)
      expect { described_class.new(confirm_cta: 'В' * 36) }.to raise_error(ArgumentError)
    end

    it 'uses universal non-medical default labels and supports custom label overrides' do
      default_schema = JSON.parse(described_class.new(locale: 'ru').to_json)
      default_form_children = default_schema['screens'].first.dig('layout', 'children', 1, 'children')
      expect(default_form_children.find { |c| c['name'] == 'service_id' }['label']).to eq('Услуга')
      expect(default_form_children.find { |c| c['name'] == 'resource_id' }['label']).to eq('Специалист')

      custom_schema = JSON.parse(
        described_class.new(
          locale: 'ru',
          specialist_label: 'Мастер',
          service_label: 'Процедура',
          confirm_cta: 'Подтвердить визит'
        ).to_json
      )
      custom_booking_children = custom_schema['screens'].first.dig('layout', 'children', 1, 'children')
      custom_details_children = custom_schema['screens'].last.dig('layout', 'children', 2, 'children')

      expect(custom_booking_children.find { |c| c['name'] == 'service_id' }['label']).to eq('Процедура')
      expect(custom_booking_children.find { |c| c['name'] == 'resource_id' }['label']).to eq('Мастер')
      expect(custom_details_children.find { |c| c['type'] == 'Footer' }['label']).to eq('Подтвердить визит')
    end
  end
end

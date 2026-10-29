require 'rails_helper'
require 'cgi'
require 'csv'
require 'zlib'

RSpec.describe 'CRM Deals CSV & XLSX Export API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  let(:no_crm_user) do
    role = CustomRole.create!(
      account: account, name: 'Оператор без CRM', description: 'Только чаты',
      permissions: %w[conversation_manage]
    )
    user = create(:user, account: account, role: :agent)
    user.account_users.find_by!(account: account).update!(custom_role: role)
    user
  end

  let(:marketer) do
    role = CustomRole.create!(
      account: account, name: 'Маркетолог CRM без ИИН', description: 'Видит сделки без ИИН',
      permissions: %w[crm_deal_view contact_manage]
    )
    user = create(:user, account: account, role: :agent)
    user.account_users.find_by!(account: account).update!(custom_role: role)
    user
  end

  let(:coordinator) do
    role = CustomRole.create!(
      account: account, name: 'Руководитель с ИИН', description: 'Видит сделки и ИИН',
      permissions: %w[crm_deal_view contact_manage contact_iin_view]
    )
    user = create(:user, account: account, role: :agent)
    user.account_users.find_by!(account: account).update!(custom_role: role)
    user
  end

  let(:export_path) { "/api/v1/accounts/#{account.id}/crm/deals/export" }
  let(:leading_zero_iin) { '040506500123' }

  before do
    account.enable_features!('crm_deals')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  def unpack_zip_entries(binary)
    bytes = binary.b
    entries = {}
    offset = 0
    while offset + 4 <= bytes.bytesize && bytes[offset, 4] == "PK\x03\x04".b
      filename, content, offset = read_local_zip_entry(bytes, offset)
      entries[filename] = content
    end
    entries
  end

  def read_local_zip_entry(bytes, offset)
    header = bytes[offset, 30].unpack('VvvvvvVVVvv')
    method = header[3]
    comp_size = header[7]
    name_len = header[9]
    extra_len = header[10]
    filename = bytes[offset + 30, name_len].force_encoding('UTF-8')
    data_start = offset + 30 + name_len + extra_len
    raw = inflate_zip_payload(method, bytes[data_start, comp_size])
    [filename, raw.force_encoding('UTF-8'), data_start + comp_size]
  end

  def inflate_zip_payload(method, compressed)
    return compressed unless method == 8

    inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
    out = inflater.inflate(compressed)
    inflater.close
    out
  end

  def seed_green_clinic_deal_fields!
    create(
      :crm_field_definition,
      account: account, entity_kind: 'deal', key: 'medical_direction', label: 'Направление',
      field_type: 'select', position: 10,
      options: [{ 'label' => 'Стоматология', 'value' => 'dentistry' }, { 'label' => 'Терапия', 'value' => 'therapy' }]
    )
    [
      ['entry_code', 'Код точки входа', 'text', 11],
      ['utm_source', 'UTM Source', 'text', 12],
      ['meta_ad_id', 'Meta Ad ID', 'text', 13],
      ['contract_paid', 'Договор оплачен', 'checkbox', 14]
    ].each do |key, label, field_type, pos|
      create(:crm_field_definition, account: account, entity_kind: 'deal', key: key, label: label, field_type: field_type, position: pos)
    end
  end

  def seed_stage_visits!(created_deal, pipeline, stages)
    base_time = 3.hours.ago.change(usec: 0)
    Crm::StageVisit.where(deal_id: created_deal.id).delete_all
    [
      [stages[0], base_time, base_time + 30.minutes],
      [stages[1], base_time + 30.minutes, base_time + 120.minutes],
      [stages[2], base_time + 120.minutes, nil]
    ].each do |stage, entered, exited|
      create(
        :crm_stage_visit,
        account: account, deal: created_deal, pipeline: pipeline, stage: stage,
        pipeline_name: pipeline.name, stage_name: stage.name, stage_outcome: stage.outcome,
        entered_at: entered, exited_at: exited, reliable_since: base_time
      )
    end
  end

  it 'denies export to custom roles without crm_deal_view / crm_deal_manage' do
    get export_path, headers: no_crm_user.create_new_auth_token
    expect(response).to have_http_status(:unauthorized).or have_http_status(:forbidden)
  end

  describe 'CSV and multi-sheet XLSX export with custom attributes, stage visits, and RBAC IIN masking' do
    let(:pipeline) { account.crm_pipelines.find_by!(code: 'sales_pipeline') }
    let(:stages) { pipeline.stages.ordered.first(3) }
    let(:patient) do
      create(
        :contact,
        account: account, name: 'Дамир Касымов', phone_number: '+77021112233',
        email: 'damir@example.com', identifier: leading_zero_iin,
        custom_attributes: { 'iin' => leading_zero_iin }
      )
    end
    let!(:deal) do
      seed_green_clinic_deal_fields!
      created = Crm::Deals::UpsertService.new(
        account: account,
        actor: admin,
        params: {
          title: '=SUM(1,2) Имплантация Green Clinic',
          pipeline_id: pipeline.id,
          stage_id: stages[2].id,
          owner_id: admin.id,
          amount_minor: 18_500_000,
          currency: 'KZT',
          primary_contact_id: patient.id,
          contact_ids: [patient.id],
          custom_attributes: {
            'medical_direction' => 'dentistry',
            'entry_code' => 'GC-IG-DENT-01',
            'utm_source' => 'instagram',
            'meta_ad_id' => 'meta_ad_778899',
            'contract_paid' => true
          }
        }
      ).perform
      seed_stage_visits!(created, pipeline, stages)
      created
    end

    it 'exports UTF-8 BOM CSV with custom attributes, stage visit durations, and formula-injection escaping' do
      get export_path,
          params: { pipeline_id: pipeline.id, export_format: 'csv' },
          headers: coordinator.create_new_auth_token

      expect(response).to have_http_status(:ok)
      raw = response.body.b
      expect(raw.bytes[0, 3]).to eq([0xEF, 0xBB, 0xBF])

      row = CSV.parse(raw.byteslice(3..).force_encoding('UTF-8'), headers: true).first
      expect(row.to_h).to include(
        'ID сделки' => deal.id.to_s,
        'Сумма' => '185000',
        'Валюта' => 'KZT',
        'ИИН контакта' => leading_zero_iin,
        'Направление (medical_direction)' => 'Стоматология',
        'Код точки входа (entry_code)' => 'GC-IG-DENT-01',
        'UTM Source (utm_source)' => 'instagram',
        'Meta Ad ID (meta_ad_id)' => 'meta_ad_778899',
        'Договор оплачен (contract_paid)' => 'Да',
        'Посещено этапов' => '3',
        'Кол-во переходов между этапами' => '2',
        "Длительность: #{stages[0].name} (мин)" => '30.0',
        "Длительность: #{stages[1].name} (мин)" => '90.0'
      )
      expect(row['Название']).to start_with("'=SUM(1,2)")
      expect(row['Время на текущем этапе (мин)'].to_f).to be_within(1.0).of(60.0)
      expect(row['Общее время в воронке (мин)'].to_f).to be_within(1.0).of(180.0)
      expect(row['Маршрут по этапам (история и длительность)']).to include(stages[0].name, stages[1].name, stages[2].name)
    end

    it 'exports valid multi-sheet OOXML .xlsx with Deals and Stage Visits sheets' do
      get export_path,
          params: { pipeline_id: pipeline.id, export_format: 'xlsx' },
          headers: admin.create_new_auth_token

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')

      entries = unpack_zip_entries(response.body)
      expect(entries.keys).to include(
        '[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels',
        'xl/styles.xml', 'xl/worksheets/sheet1.xml', 'xl/worksheets/sheet2.xml'
      )
      expect(entries['xl/workbook.xml']).to include('name="Сделки"', 'name="История этапов"')
      expect(CGI.unescapeHTML(entries['xl/worksheets/sheet1.xml'])).to include(
        'Стоматология', 'GC-IG-DENT-01', 'meta_ad_778899', leading_zero_iin, "'=SUM(1,2)"
      )
      expect(entries['xl/worksheets/sheet2.xml']).to include(
        stages[0].name, stages[1].name, stages[2].name, '<v>1800</v>', '<v>5400</v>'
      )
    end

    it 'masks contact IIN in both CSV and XLSX exports for custom roles without contact_iin_view' do
      headers = marketer.create_new_auth_token

      get export_path, params: { pipeline_id: pipeline.id, export_format: 'csv' }, headers: headers
      csv_text = response.body.b.byteslice(3..).force_encoding('UTF-8')
      expect(csv_text).not_to include(leading_zero_iin)
      expect(CSV.parse(csv_text, headers: true).first['ИИН контакта']).to eq(Contacts::IinPrivacy::MASKED_IIN)

      get export_path, params: { pipeline_id: pipeline.id, export_format: 'xlsx' }, headers: headers
      entries = unpack_zip_entries(response.body)
      expect(entries['xl/worksheets/sheet1.xml']).not_to include(leading_zero_iin)
      expect(entries['xl/worksheets/sheet1.xml']).to include(Contacts::IinPrivacy::MASKED_IIN)
    end

    it 'reports 0 active dwell for terminal won visits, escapes CSV formula headers, and writes valid DOS ZIP date' do
      won_stage = pipeline.stages.find_by!(outcome: 'won')
      base_time = 2.days.ago.change(usec: 0)
      deal.update!(stage: won_stage, custom_attributes: deal.custom_attributes.merge('=evil_col' => " \t=1+1"))
      Crm::StageVisit.where(deal_id: deal.id).delete_all
      [
        [stages[0], base_time, base_time + 30.minutes],
        [stages[1], base_time + 30.minutes, base_time + 120.minutes],
        [won_stage, base_time + 120.minutes, nil]
      ].each do |st, entered, exited|
        create(:crm_stage_visit, account: account, deal: deal, pipeline: pipeline, stage: st,
                                 pipeline_name: pipeline.name, stage_name: st.name, stage_outcome: st.outcome,
                                 entered_at: entered, exited_at: exited, reliable_since: base_time)
      end

      headers = admin.create_new_auth_token
      get export_path, params: { pipeline_id: pipeline.id, export_format: 'csv' }, headers: headers
      parsed = CSV.parse(response.body.b.byteslice(3..).force_encoding('UTF-8'), headers: true)
      expect(parsed.headers).to include("'=evil_col")
      expect(parsed.first["'=evil_col"]).to start_with("' \t=1+1")
      expect(parsed.first.to_h).to include(
        'Время на текущем этапе (мин)' => '0.0',
        'Общее время в воронке (мин)' => '120.0'
      )

      get export_path, params: { pipeline_id: pipeline.id, export_format: 'xlsx' }, headers: headers
      dos_date = response.body.b[12, 2].unpack1('v')
      expect(dos_date).to eq(0x0021)
      sheet2 = unpack_zip_entries(response.body)['xl/worksheets/sheet2.xml']
      expect(sheet2).not_to include('>Да<')
    end
  end
end

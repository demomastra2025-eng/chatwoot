# rubocop:disable Metrics/ClassLength
class Integrations::Moysklad::ProductsSyncService
  SUPPORTED_PRODUCT_TYPES = %w[product variant bundle].freeze
  STOCK_TRACKED_TYPES = %w[product variant].freeze
  DEFAULT_PRICE_TYPE_NAME = 'Цена продажи'.freeze

  def initialize(account:, hook: nil, access_token: nil, price_type_name: nil)
    @account = account
    @hook = hook || account.hooks.find_by(app_id: 'moysklad')
    @access_token = access_token.presence || resolve_hook_token(@hook)
    @price_type_name = price_type_name.presence ||
                       @hook&.settings&.dig('price_type_name').presence ||
                       DEFAULT_PRICE_TYPE_NAME
  end

  def perform
    client = Integrations::Moysklad::ApiClient.new(access_token: @access_token)
    stores = client.fetch_stores
    context = build_sync_context(client, stores)
    counts = upsert_assortment_rows!(context)

    summary = {
      synced_at: context[:synced_at].iso8601,
      total_synced: counts[:total],
      created_count: counts[:created],
      updated_count: counts[:updated],
      stores_count: stores.size,
      price_type_name: @price_type_name
    }
    persist_hook_sync_summary!(summary) if @hook.present?
    summary
  end

  private

  def build_sync_context(client, stores)
    store_names = stores.each_with_object({}) do |store, acc|
      acc[store['id'].to_s] = store['name'].to_s if store['id'].present?
    end
    assortment_rows = client.fetch_all_assortment

    {
      rows: assortment_rows,
      products_by_id: index_base_products(assortment_rows),
      stock_by_id: index_stock_by_id(assortment_rows),
      stock_by_assortment: build_stock_by_assortment_map(client.fetch_stock_by_store, store_names),
      synced_at: Time.current
    }
  end

  def index_base_products(rows)
    rows.each_with_object({}) do |row, acc|
      acc[row['id'].to_s] = row if extract_meta_type(row) == 'product'
    end
  end

  def index_stock_by_id(rows)
    rows.each_with_object({}) do |row, acc|
      next unless STOCK_TRACKED_TYPES.include?(extract_meta_type(row))

      acc[row['id'].to_s] = {
        stock: row['stock'].to_d,
        reserve: row['reserve'].to_d,
        in_transit: row['inTransit'].to_d,
        quantity: row['quantity'].to_d
      }
    end
  end

  def upsert_assortment_rows!(context)
    counts = { total: 0, created: 0, updated: 0 }

    ApplicationRecord.transaction do
      context[:rows].each do |row|
        item_type = extract_meta_type(row)
        external_id = row['id'].to_s
        next if external_id.blank? || SUPPORTED_PRODUCT_TYPES.exclude?(item_type)

        was_new = upsert_single_product!(row, item_type, external_id, context)
        counts[:total] += 1
        counts[was_new ? :created : :updated] += 1
      end
    end

    counts
  end

  def upsert_single_product!(row, item_type, external_id, context)
    product = @account.scheduling_products.find_or_initialize_by(
      external_source: 'moysklad',
      external_id: external_id
    )
    was_new = product.new_record?
    product.assign_attributes(build_product_attributes(row, item_type, context))
    product.save!
    was_new
  end

  def resolve_hook_token(hook)
    return nil if hook.blank?

    hook.secret_settings['api_token'].presence || hook.access_token.presence
  end

  def extract_meta_type(row)
    row.dig('meta', 'type').to_s
  end

  def extract_uuid_from_href(href)
    return nil if href.blank?

    href.to_s.split('/').last&.split('?')&.first
  end

  def build_stock_by_assortment_map(raw_rows, store_names_by_id)
    raw_rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |entry, acc|
      assortment_id = entry['assortmentId'].to_s
      store_id = entry['storeId'].to_s
      next if assortment_id.blank? || store_id.blank?

      stock = entry['stock'].to_f
      reserve = entry['reserve'].to_f
      acc[assortment_id] << {
        'store_id' => store_id,
        'store_name' => store_names_by_id[store_id].presence || 'Склад',
        'stock' => stock,
        'reserve' => reserve,
        'in_transit' => entry['inTransit'].to_f,
        'available' => stock - reserve
      }
    end
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity
  def build_product_attributes(row, item_type, context)
    external_id = row['id'].to_s
    parent_id = extract_uuid_from_href(row.dig('product', 'meta', 'href')) if item_type == 'variant'
    parent_row = parent_id.present? ? context[:products_by_id][parent_id] : nil
    sale_prices = normalize_sale_prices(row['salePrices'])
    stock_values = resolve_stock_values(row, item_type, context[:stock_by_id])

    {
      name: row['name'].to_s.strip.presence || 'Без названия',
      item_type: item_type,
      code: row['code'].presence,
      article: row['article'].presence || parent_row&.dig('article').presence,
      category: resolve_category(row, parent_row),
      uom: resolve_uom(row, parent_row),
      description: row['description'].presence || parent_row&.dig('description').presence,
      price: resolve_primary_price(sale_prices),
      wholesale_price: resolve_named_price(sale_prices, /оптов|wholesale/i),
      kaspi_price: resolve_named_price(sale_prices, /kaspi|каспи/i),
      buy_price: minor_to_kzt(row.dig('buyPrice', 'value')),
      min_price: minor_to_kzt(row.dig('minPrice', 'value')),
      currency: 'KZT',
      stock: stock_values[:stock],
      reserve: stock_values[:reserve],
      in_transit: stock_values[:in_transit],
      quantity: stock_values[:quantity],
      active: !ActiveModel::Type::Boolean.new.cast(row['archived']),
      parent_external_id: parent_id,
      barcodes: Array(row['barcodes']),
      characteristics: normalize_characteristics(row['characteristics']),
      sale_prices: sale_prices,
      store_stocks: context[:stock_by_assortment][external_id] || [],
      custom_attributes: normalize_custom_attributes(row['attributes'], parent_row&.dig('attributes')),
      synced_at: context[:synced_at]
    }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity

  def minor_to_kzt(raw_value)
    return 0 if raw_value.nil?

    (raw_value.to_f / 100.0).round
  end

  def normalize_sale_prices(raw_prices)
    Array(raw_prices).filter_map do |price_entry|
      next unless price_entry.is_a?(Hash)

      name = price_entry.dig('priceType', 'name').to_s.strip
      next if name.blank?

      {
        'id' => price_entry.dig('priceType', 'id').to_s.presence,
        'name' => name,
        'value' => minor_to_kzt(price_entry['value'])
      }
    end
  end

  def resolve_primary_price(sale_prices)
    return 0 if sale_prices.empty?

    matched = sale_prices.find { |sp| sp['name'].casecmp?(@price_type_name.to_s.strip) } ||
              sale_prices.find { |sp| sp['name'].casecmp?(DEFAULT_PRICE_TYPE_NAME) } ||
              sale_prices.first
    matched ? matched['value'].to_i : 0
  end

  def resolve_named_price(sale_prices, pattern)
    matched = sale_prices.find { |sp| sp['name'].to_s.match?(pattern) }
    matched ? matched['value'].to_i : nil
  end

  def resolve_category(row, parent_row)
    source = row['productFolder'].present? || row['pathName'].present? ? row : (parent_row || row)
    folder = source['productFolder']
    if folder.is_a?(Hash) && folder['name'].present?
      [folder['pathName'].presence, folder['name']].compact.join('/').squeeze('/')
    else
      source['pathName'].to_s.strip.presence
    end
  end

  def resolve_uom(row, parent_row)
    row.dig('uom', 'name').presence || parent_row&.dig('uom', 'name').presence || 'шт'
  end

  def resolve_stock_values(row, item_type, stock_by_id)
    return compute_bundle_stock_values(row, stock_by_id) if item_type == 'bundle' && row['stock'].nil?

    stock = row['stock'].to_d
    reserve = row['reserve'].to_d
    in_transit = row['inTransit'].to_d
    quantity = row['quantity'].nil? ? (stock - reserve + in_transit) : row['quantity'].to_d

    { stock: stock, reserve: reserve, in_transit: in_transit, quantity: quantity }
  end

  def compute_bundle_stock_values(row, stock_by_id)
    availables = Array(row.dig('components', 'rows')).filter_map do |comp|
      comp_id = extract_uuid_from_href(comp.dig('assortment', 'meta', 'href'))
      qty_needed = comp['quantity'].to_d
      comp_stock = comp_id.present? && qty_needed.positive? ? stock_by_id[comp_id] : nil
      next unless comp_stock

      ((comp_stock[:stock] - comp_stock[:reserve]) / qty_needed).floor
    end
    bundle_avail = availables.present? ? [availables.min, 0].max.to_d : 0.to_d
    { stock: bundle_avail, reserve: 0.to_d, in_transit: 0.to_d, quantity: bundle_avail }
  end

  def normalize_characteristics(raw_characteristics)
    Array(raw_characteristics).filter_map do |ch|
      next unless ch.is_a?(Hash) && ch['name'].present?

      { 'id' => ch['id'].to_s.presence, 'name' => ch['name'].to_s, 'value' => ch['value'].to_s }
    end
  end

  def normalize_custom_attributes(raw_attrs, parent_raw_attrs = nil)
    merged = {}
    [parent_raw_attrs, raw_attrs].compact.each do |list|
      Array(list).each do |attr|
        next unless attr.is_a?(Hash) && attr['name'].present?

        val = attr['value']
        merged[attr['name'].to_s] = val.is_a?(Hash) && val.key?('name') ? val['name'] : val
      end
    end
    merged
  end

  def persist_hook_sync_summary!(summary)
    current_settings = @hook.settings.is_a?(Hash) ? @hook.settings.deep_dup : {}
    current_settings['last_synced_at'] = summary[:synced_at]
    current_settings['last_sync_summary'] = summary.stringify_keys
    @hook.update!(settings: current_settings)
  end
end
# rubocop:enable Metrics/ClassLength

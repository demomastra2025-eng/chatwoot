require 'rails_helper'

RSpec.describe 'Scheduling Products & MoySklad Sync API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { admin.create_new_auth_token }
  let(:agent_headers) { agent.create_new_auth_token }
  let(:base_path) { "/api/v1/accounts/#{account.id}/scheduling/products" }

  def response_body
    response.parsed_body
  end

  describe 'CRUD operations' do
    it 'lists active products by default and includes inactive when requested' do
      active_product = create(:scheduling_product, account: account, name: 'iPhone 16 Pro', active: true)
      inactive_product = create(:scheduling_product, account: account, name: 'Archived Case', active: false)

      get base_path, headers: agent_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response_body['payload'].pluck('id')).to contain_exactly(active_product.id)

      get base_path, params: { include_inactive: true }, headers: agent_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response_body['payload'].pluck('id')).to contain_exactly(active_product.id, inactive_product.id)
    end

    it 'creates, updates, and deletes a product with stock & price calculations' do
      post base_path,
           params: {
             name: 'Смартфон Apple iPhone 16 Pro',
             item_type: 'product',
             code: 'IP16PRO-BASE',
             article: 'A3293',
             category: 'Электроника/Смартфоны и гаджеты',
             uom: 'шт',
             price: '649990.0',
             wholesale_price: '595000',
             kaspi_price: '679990',
             buy_price: '480000',
             min_price: '560000',
             stock: 14,
             reserve: 2,
             in_transit: 6,
             custom_attributes: { 'Бренд' => 'Apple', 'Гарантия (мес)' => 12 }
           },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:created)
      payload = response_body['payload']
      expect(payload).to include(
        'name' => 'Смартфон Apple iPhone 16 Pro',
        'price' => 649_990,
        'wholesale_price' => 595_000,
        'kaspi_price' => 679_990,
        'stock' => 14.0,
        'reserve' => 2.0,
        'in_transit' => 6.0,
        'available_now' => 12.0,
        'quantity' => 18.0
      )
      expect(payload['custom_attributes']).to include('Бренд' => 'Apple', 'Гарантия (мес)' => 12)

      product_id = payload['id']

      patch "#{base_path}/#{product_id}",
            params: { stock: 20, reserve: 5, price: 639_990 },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:ok)
      expect(response_body['payload']).to include(
        'price' => 639_990,
        'available_now' => 15.0,
        'quantity' => 21.0
      )

      delete "#{base_path}/#{product_id}", headers: headers, as: :json
      expect(response).to have_http_status(:no_content)
      expect(Scheduling::Product.exists?(product_id)).to be(false)
    end
  end

  describe 'MoySklad integration & synchronization' do
    let(:ms_stores_response) do
      {
        rows: [
          { id: 'store-almaty', name: 'Склад Алматы (Абая 10)' },
          { id: 'store-astana', name: 'Шоурум Астана (Достык 5)' }
        ]
      }.to_json
    end

    let(:ms_stock_by_store_response) do
      [
        {
          assortmentId: 'prod-iphone-16',
          storeId: 'store-almaty',
          stock: 10.0,
          reserve: 2.0,
          inTransit: 6.0
        },
        {
          assortmentId: 'prod-iphone-16',
          storeId: 'store-astana',
          stock: 4.0,
          reserve: 0.0,
          inTransit: 0.0
        }
      ].to_json
    end

    let(:ms_assortment_response) do
      {
        meta: { size: 4, limit: 100, offset: 0 },
        rows: [
          {
            id: 'prod-iphone-16',
            meta: { type: 'product', href: 'https://api.moysklad.ru/api/remap/1.2/entity/product/prod-iphone-16' },
            name: 'Смартфон Apple iPhone 16 Pro',
            code: 'IP16PRO-BASE',
            article: 'A3293',
            description: 'Флагманский смартфон Apple',
            archived: false,
            stock: 14.0,
            reserve: 2.0,
            inTransit: 6.0,
            quantity: 18.0,
            productFolder: { name: 'Смартфоны и гаджеты', pathName: 'Электроника' },
            uom: { name: 'шт' },
            buyPrice: { value: 48_000_000.0 },
            minPrice: { value: 56_000_000.0 },
            salePrices: [
              { value: 64_999_000.0, priceType: { id: 'pt-1', name: 'Цена продажи' } },
              { value: 59_500_000.0, priceType: { id: 'pt-2', name: 'Оптовая цена' } },
              { value: 67_999_000.0, priceType: { id: 'pt-3', name: 'Цена Kaspi Магазин' } }
            ],
            barcodes: [{ ean13: '1959498218990' }],
            attributes: [
              { name: 'Бренд', value: { name: 'Apple' } },
              { name: 'Гарантия (мес)', value: 12 },
              { name: 'Хит продаж', value: true }
            ]
          },
          {
            id: 'var-iphone-nat-256',
            meta: { type: 'variant', href: 'https://api.moysklad.ru/api/remap/1.2/entity/variant/var-iphone-nat-256' },
            name: 'Смартфон Apple iPhone 16 Pro (Natural Titanium, 256GB)',
            code: 'IP16P-NAT-256',
            archived: false,
            stock: 7.0,
            reserve: 1.0,
            inTransit: 0.0,
            quantity: 6.0,
            product: {
              meta: { href: 'https://api.moysklad.ru/api/remap/1.2/entity/product/prod-iphone-16' }
            },
            characteristics: [
              { id: 'ch-1', name: 'Цвет', value: 'Natural Titanium' },
              { id: 'ch-2', name: 'Память', value: '256GB' }
            ],
            salePrices: [
              { value: 64_999_000.0, priceType: { id: 'pt-1', name: 'Цена продажи' } }
            ]
          },
          {
            id: 'bndl-iphone-full',
            meta: { type: 'bundle', href: 'https://api.moysklad.ru/api/remap/1.2/entity/bundle/bndl-iphone-full' },
            name: 'Комбо-набор «iPhone 16 Pro Под Ключ»',
            code: 'BNDL-IP16P-FULL',
            archived: false,
            stock: nil,
            productFolder: { name: 'Смартфоны и гаджеты', pathName: 'Электроника' },
            components: {
              rows: [
                {
                  quantity: 1.0,
                  assortment: {
                    meta: { href: 'https://api.moysklad.ru/api/remap/1.2/entity/product/prod-iphone-16' }
                  }
                }
              ]
            },
            salePrices: [
              { value: 66_499_000.0, priceType: { id: 'pt-1', name: 'Цена продажи' } }
            ]
          },
          {
            id: 'srv-setup',
            meta: { type: 'service', href: 'https://api.moysklad.ru/api/remap/1.2/entity/service/srv-setup' },
            name: 'Наклейка защитного стекла',
            code: 'SRV-SETUP',
            salePrices: [
              { value: 500_000.0, priceType: { id: 'pt-1', name: 'Цена продажи' } }
            ]
          }
        ]
      }.to_json
    end

    before do
      stub_request(:get, 'https://api.moysklad.ru/api/remap/1.2/entity/store?limit=100')
        .to_return(status: 200, body: ms_stores_response, headers: { 'Content-Type' => 'application/json' })

      stub_request(:get, 'https://api.moysklad.ru/api/remap/1.2/report/stock/bystore/current')
        .to_return(status: 200, body: ms_stock_by_store_response, headers: { 'Content-Type' => 'application/json' })

      stub_request(:get, 'https://api.moysklad.ru/api/remap/1.2/entity/assortment?expand=productFolder,uom,components&limit=100&offset=0')
        .to_return(status: 200, body: ms_assortment_response, headers: { 'Content-Type' => 'application/json' })
    end

    # rubocop:disable RSpec/MultipleExpectations
    it 'saves MoySklad config and syncs products, variants, and bundles while skipping services' do
      post "#{base_path}/sync_moysklad",
           params: {
             access_token: '8d66ea6fcbdfbe239d4b61d619049f28e8253bfb',
             price_type_name: 'Цена продажи'
           },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      meta = response_body['meta']
      expect(meta['sync_summary']).to include('total_synced' => 3, 'created_count' => 3)
      expect(meta['moysklad']).to include('connected' => true, 'masked_token' => '8d66••••3bfb')

      products = response_body['payload']
      expect(products.size).to eq(3)

      base_iphone = products.find { |p| p['external_id'] == 'prod-iphone-16' }
      expect(base_iphone).to include(
        'price' => 649_990,
        'wholesale_price' => 595_000,
        'kaspi_price' => 679_990,
        'buy_price' => 480_000,
        'min_price' => 560_000,
        'category' => 'Электроника/Смартфоны и гаджеты',
        'stock' => 14.0,
        'reserve' => 2.0,
        'in_transit' => 6.0,
        'available_now' => 12.0,
        'quantity' => 18.0
      )
      expect(base_iphone['store_stocks'].size).to eq(2)
      expect(base_iphone['custom_attributes']).to include('Бренд' => 'Apple', 'Гарантия (мес)' => 12, 'Хит продаж' => true)

      variant_iphone = products.find { |p| p['external_id'] == 'var-iphone-nat-256' }
      expect(variant_iphone).to include(
        'item_type' => 'variant',
        'parent_external_id' => 'prod-iphone-16',
        'category' => 'Электроника/Смартфоны и гаджеты'
      )
      expect(variant_iphone['characteristics']).to eq(
        [
          { 'id' => 'ch-1', 'name' => 'Цвет', 'value' => 'Natural Titanium' },
          { 'id' => 'ch-2', 'name' => 'Память', 'value' => '256GB' }
        ]
      )

      bundle_iphone = products.find { |p| p['external_id'] == 'bndl-iphone-full' }
      expect(bundle_iphone).to include(
        'item_type' => 'bundle',
        'price' => 664_990,
        'available_now' => 12.0
      )
    end
    # rubocop:enable RSpec/MultipleExpectations
  end
end

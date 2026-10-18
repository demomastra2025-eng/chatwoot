# == Schema Information
#
# Table name: scheduling_products
#
#  id                 :bigint           not null, primary key
#  active             :boolean          default(TRUE), not null
#  article            :string
#  barcodes           :jsonb            not null
#  buy_price          :bigint           default(0), not null
#  category           :string
#  characteristics    :jsonb            not null
#  code               :string
#  currency           :string           default("KZT"), not null
#  custom_attributes  :jsonb            not null
#  description        :text
#  in_transit         :decimal(14, 3)   default(0.0), not null
#  item_type          :string           default("product"), not null
#  kaspi_price        :bigint
#  min_price          :bigint           default(0), not null
#  name               :string           not null
#  price              :bigint           default(0), not null
#  quantity           :decimal(14, 3)   default(0.0), not null
#  reserve            :decimal(14, 3)   default(0.0), not null
#  sale_prices        :jsonb            not null
#  stock              :decimal(14, 3)   default(0.0), not null
#  store_stocks       :jsonb            not null
#  synced_at          :datetime
#  uom                :string           default("шт"), not null
#  wholesale_price    :bigint
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :bigint           not null
#  external_id        :string
#  external_source    :string
#  parent_external_id :string
#
class Scheduling::Product < ApplicationRecord
  ITEM_TYPES = %w[product variant bundle].freeze
  ARRAY_JSON_FIELDS = %i[barcodes characteristics sale_prices store_stocks].freeze

  belongs_to :account

  validates :name, presence: true
  validates :item_type, inclusion: { in: ITEM_TYPES }
  validates :price, :buy_price, :min_price,
            numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :wholesale_price, :kaspi_price,
            numericality: { greater_than_or_equal_to: 0, only_integer: true },
            allow_nil: true
  validates :external_id,
            uniqueness: { scope: [:account_id, :external_source] },
            allow_nil: true

  before_validation :normalize_defaults
  before_validation :recalculate_quantity_if_stock_changed

  scope :ordered, -> { order(:name, :id) }
  scope :active, -> { where(active: true) }

  def available_now
    (stock.to_d - reserve.to_d).to_f
  end

  private

  def normalize_defaults
    self.item_type = item_type.presence || 'product'
    self.uom = uom.presence || 'шт'
    self.currency = currency.presence || 'KZT'
    ARRAY_JSON_FIELDS.each do |field|
      public_send(:"#{field}=", []) unless public_send(field).is_a?(Array)
    end
    self.custom_attributes = {} unless custom_attributes.is_a?(Hash)
  end

  def recalculate_quantity_if_stock_changed
    if will_save_change_to_quantity? &&
       !will_save_change_to_stock? &&
       !will_save_change_to_reserve? &&
       !will_save_change_to_in_transit?
      return
    end

    self.quantity = stock.to_d - reserve.to_d + in_transit.to_d
  end
end

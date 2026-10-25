# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::TextDiff do
  def diff(old_text, new_text) = described_class.unified(old_text, new_text, from: 'old', to: 'new')

  it 'is empty for the same texts, a final line end included' do
    expect(diff("a\nb", "a\nb\n")).to eq('')
    expect(diff(nil, '')).to eq('')
  end

  it 'writes a changed line with three lines of context, as diff -u does' do
    old_text = (1..10).map { |n| "line #{n}" }.join("\n")
    new_text = old_text.sub('line 5', 'line five')

    expect(diff(old_text, new_text)).to eq(<<~DIFF)
      --- old
      +++ new
      @@ -2,7 +2,7 @@
       line 2
       line 3
       line 4
      -line 5
      +line five
       line 6
       line 7
       line 8
    DIFF
  end

  it 'writes far changes as separate hunks and close ones as one' do
    old_text = (1..20).map { |n| "line #{n}" }.join("\n")
    far = old_text.sub('line 2', 'line two').sub('line 18', 'line eighteen')
    close = old_text.sub('line 2', 'line two').sub('line 8', 'line eight')

    expect(diff(old_text, far).scan(/^@@ .* @@$/)).to eq(['@@ -1,5 +1,5 @@', '@@ -15,6 +15,6 @@'])
    expect(diff(old_text, close).scan(/^@@ .* @@$/)).to eq(['@@ -1,11 +1,11 @@'])
  end

  it 'writes a text that was empty as added, and one that becomes empty as removed' do
    expect(diff('', "Клиника:\n- МО «Тест»")).to eq("--- old\n+++ new\n@@ -0,0 +1,2 @@\n+Клиника:\n+- МО «Тест»\n")
    expect(diff('Старый текст', '')).to eq("--- old\n+++ new\n@@ -1 +0,0 @@\n-Старый текст\n")
  end

  it 'keeps the lines both texts share and shows only the lines that differ' do
    expect(diff("a\nb\nc\nd", "a\nc\nd\ne")).to eq("--- old\n+++ new\n@@ -1,4 +1,4 @@\n a\n-b\n c\n d\n+e\n")
  end

  it 'still gives a correct diff above the size of the table: everything that differs is removed, then added' do
    stub_const("#{described_class}::MAX_TABLE_CELLS", 1)

    expect(diff("a\nb\nc", "a\nB\nc")).to eq("--- old\n+++ new\n@@ -1,3 +1,3 @@\n a\n-b\n-c\n+B\n+c\n")
  end
end

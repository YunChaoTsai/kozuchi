# 異動明細クラス。
class Deal < BaseDeal
  attr_accessor :minus_account_id, :plus_account_id, :amount, :minus_account_friend_link_id, :plus_account_friend_link_id
  has_many   :children,
             :class_name => 'SubordinateDeal',
             :foreign_key => 'parent_deal_id',
             :dependent => true

  # 移行中
  # 借方（資産の増加、費用の発生、負債・資本の減少、収益の取消し）にくる記入。
  # 小槌では、これらはすべて 金額がプラスであることで表現される。
  has_many   :left_entries,
             :class_name => 'AccountEntry',
             :foreign_key => 'deal_id',
             :dependent => :destroy,
             :conditions => 'amount >= 0',
             :include => :account

  # 貸方（資産の減少、負債の増加、資本の増加、収益の発生、費用の取消）
  # 小槌では、これらはすべて 金額がマイナスであることで表現される
  has_many   :right_entries,
             :class_name => 'AccountEntry',
             :foreign_key => 'deal_id',
             :dependent => :destroy,
             :conditions => 'amount < 0',
             :include => :account

  def before_validation
    # もし金額にカンマが入っていたら正規化する
    @amount = @amount.gsub(/,/,'') if @amount.class == String
  end

  def validate
    errors.add_to_base("同じ口座から口座への異動は記録できません。") if self.minus_account_id && self.plus_account_id && self.minus_account_id.to_i == self.plus_account_id.to_i
    errors.add_to_base("金額が0となっています。") if @amount.to_i == 0
  end

  # summary の前方一致で検索する
  def self.search_by_summary(user_id, summary_key, limit)
    begin
    return [] if summary_key.empty?
    # まず summary と 日付(TODO: created_at におきかえたい)のセットを返す
    p "search_by_summary : summary_key = #{summary_key}"
    results = find_by_sql("select summary as summary, max(date) as date from deals where user_id = #{user_id} and type='Deal' and summary like '#{summary_key}%' group by summary limit #{limit}")
    p "results.size = #{results.size}"
    return [] if results.size == 0
    conditions = ""
    for r in results
      conditions += " or " unless conditions.empty?
      conditions += "(summary = '#{r.summary}' and date = '#{r.date}')"
    end
    return Deal.find(:all, :conditions => "user_id = #{user_id} and (#{conditions})")
    rescue => err
    p err
    p err.backtrace
    return []
    end
  end

  # 自分の取引のなかに指定された口座IDが含まれるか
  def has_account(account_id)
    for entry in account_entries
      return true if entry.account.id == account_id
    end
    return false
  end
  
  # 子取引のなかに指定された口座IDが含まれればそれをかえす
  def child_for(account_id)
    for child in children
      return child if child.has_account(account_id)
    end
    return false
  end

  # ↓↓  call back methods  ↓↓

  def before_save
    pre_before_save
  end

  def after_save
    p "after_save #{self.id}"
    create_relations
  end
  
  def before_update
    clear_entries_before_update    
    children.clear
  end

  # Prepare sugar methods
  def after_find
#    p "after_find #{self.id}"
    set_old_date
    p "Invalid Deal Object #{self.id} with #{account_entries.size} entries." unless account_entries.size == 2
#    raise "Invalid Deal Object #{self.id} with #{account_entries.size} entries." unless account_entries.size == 2
    return unless account_entries.size == 2
    
    @minus_account_id = account_entries[0].account_id
    @plus_account_id = account_entries[1].account_id
    @amount = account_entries[1].amount
  end
  
  def before_destroy
    account_entries.destroy_all # account_entry の before_destroy 処理を呼ぶ必要があるため明示的に
    # フレンドリンクまたは本体までを消す
 #   clear_friend_deals
  end

  # ↑↑  call back methods  ↑↑
  
  def entry(account_id)
    for entry in account_entries
      return entry if entry.account_id.to_i == account_id.to_i
    end
    return nil
  end

  private

  def clear_entries_before_update
    for entry in account_entries
      # この取引の勘定でなくなっていたら、entryを消す
      if @plus_account_id.to_i != entry.account_id.to_i && @minus_account_id.to_i != entry.account_id.to_i
        p "plus_account_id = #{@plus_account_id} . minus_account_id = #{@minus_account_id}. this_entry_account_id = #{entry.account_id}" 
        entry.destroy
      end
    end
  end

  def clear_relations
    account_entries.clear
    children.clear
  end

  def update_account_entry(is_minus, is_first, deal_link_for_second)
    deal_link_id_for_second = deal_link_for_second ? deal_link_for_second.id : nil
    if is_minus
      entry_account_id = @minus_account_id
      entry_amount = @amount.to_i*(-1)
      entry_friend_link_id = @minus_account_friend_link_id
      entry_friend_link_id ||= deal_link_id_for_second if !is_first
      another_entry_account = is_first ? Account.find(@plus_account_id) : nil
      # second に上記をわたしても無害だが不要なため処理を省く
    else
      entry_account_id = @plus_account_id
      entry_amount = @amount.to_i
      entry_friend_link_id = @plus_account_friend_link_id
      entry_friend_link_id ||= deal_link_id_for_second if !is_first
      another_entry_account = is_first ? Account.find(@minus_account_id) : nil
      # second に上記をわたしても無害だが不要なため処理を省く
    end
    
    entry = entry(entry_account_id)
    if !entry
      entry = account_entries.create(:user_id => user_id,
                :account_id => entry_account_id,
                :friend_link_id => entry_friend_link_id,
                :amount => entry_amount,
                :another_entry_account => another_entry_account)
    else
      # 金額、日付が変わったときは変わったとみなす。サマリーだけ変えても影響なし。
      # entry.save がされるということは、リンクが消されて新しくDeal が作られるということを意味する。
      if entry_amount != entry.amount || self.old_date != self.date
        # すでにリンクがある場合、消して作り直す際は変更前のリンク先口座を優先的に選ぶ。
        if entry.linked_account_entry
          entry.account_to_be_connected = entry.linked_account_entry.account
        end
        entry.amount = entry_amount
        entry.another_entry_account = another_entry_account
        entry.friend_link_id = deal_link_id_for_second if !is_first && deal_link_id_for_second
        entry.save!
      end
    end
    return entry
  end
  
  def create_relations
    # 当該account_entryがなくなっていたら消す。金額が変更されていたら更新する。あって金額がそのままなら変更しない。
    # 小さいほうが前になるようにする。これにより、minus, plus, amount は値が逆でも差がなくなる
    entry = nil
    entry = update_account_entry(true, true, nil) if @amount.to_i >= 0     # create minus
    entry = update_account_entry(false, !entry, entry ? entry.new_plus_link : nil) # create plus
    update_account_entry(true, false, entry.new_plus_link) if @amount.to_i < 0   # create_minus
    
    account_entries(true)

    for i in 0..1
      account_rule = account_entries[i].account.account_rule(true)
      p "create_relations in deal #{self.id}: entry #{i} : account_id = #{account_entries[i].account.id} : account_rule = #{account_rule}"
      # 精算ルールに従って従属行を用意する
      if account_rule
        # どこからからルール適用口座への異動額
        new_amount = account_entries[i].amount
        # 適用口座がクレジットカードなら、出金元となっているときだけルールを適用する。債権なら入金先となっているときだけ適用する。
        if (Account::ASSET_CREDIT_CARD == account_rule.account.asset_type && new_amount < 0) ||(Account::ASSET_CREDIT == account_rule.account.asset_type && new_amount > 0)
          children.create(
            :minus_account_id => account_rule.account_id,
            :plus_account_id => account_rule.associated_account_id,
            :amount => new_amount,
            :user_id => self.user_id,
            :date => account_rule.payment_date(self.date),
#            :date => self.date  >> 1,
            :summary => "",
            :confirmed => false)
        end
      end
    end
  end
  
end

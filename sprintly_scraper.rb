require 'awesome_print'
require 'csv'
require 'httparty'

# Sprintly APIs
# Items
# /api/products/{product_id}/items.json
# /api/products/21740/items.csv?status=someday,backlog,in-progress,completed,accepted&tags=pivotal&children=true&offset=300&limit=100&order_by=oldest
#
# Comments
# /api/products/{product_id}/items/{item_number}/comments.json
#
# Attachments
# /api/products/{product_id}/items/{item_number}/attachments.json

class SprintlyScraper

  attr_accessor :credentials, :product_id

  # Sprintly  | Tracker
  # Tags      | Labels

  SPRINTLY_TO_TRACKER_TYPE_MAPPING = {
    'story' => 'feature',
    'defect' => 'bug',
    'task' => 'feature',
    'test' => 'feature'
  }

  SPRINTLY_TO_TRACKER_STATUS_MAPPING = {
    'someday' => 'unscheduled',
    'backlog' => 'unstarted',
    'in-progress' => 'started',
    'completed' => 'delivered',
    'accepted' => 'accepted'
  }

  SPRINTLY_TO_TRACKER_ESTIMATE_MAPPING = {
    '~' => -1,
    'S' => 2,
    'M' => 3,
    'L' => 5,
    'XL' => 8
  }

  MEMBER_FULL_NAME_TO_TRACKER_HANDLE = {
    "Joe Developer" => "@joedev",
    "Jane Developer" => "@janedev"
  }

  def initialize(email, api_key, product_id)
    self.credentials = {username: email, password: api_key}
    self.product_id = product_id
  end

  def export_all(out_filename)
    headers = ['Created at','Accepted at','Requested By','Owned By','Type','Estimate','Current State','Title','Description','Labels','Comment','Comment','Comment','Comment','Comment','Comment']
    [0, 100, 200, 300].each do |offset|
      CSV.open("#{out_filename}-#{offset}.csv", 'wb') do |csv|
        csv << headers
        items_json_response = items_request(offset)
        items = JSON.parse(items_json_response.body)
        items.each do |item|
          # Add the comments, if any
          comments_json_response = comments_request(item['number'])
          comments = JSON.parse(comments_json_response.body)

          # Add the attachments, if any
          attachments_json_response = attachments_request(item['number'])
          attachments = JSON.parse(attachments_json_response.body)

          csv << tokenized_item(item, comments, attachments)
        end
      end
    end

    puts 'Done'
  end

  def tokenized_item(item, comments, attachments)
    accepted_at = normalized_datetime(item['progress'], 'accepted_at')
    normalized_status = normalized_status(item['status'], accepted_at)

    item_tokens = [
      normalized_datetime(item['created_by'], 'created_at'),
      accepted_at,
      normalized_full_name(item['created_by']),
      normalized_full_name(item['assigned_to']),
      normalized_type(item['type']),
      normalized_score(normalized_status, item['score']),
      normalized_status,
      item['title'],
      item['description'],
      normalized_tags(item['tags'])
    ]

    return item_tokens if comments.empty?

    comments.each do |comment|
      item_tokens << parsed_comment(comment)
    end

    # {"message"=>"Item does not exist.", "code"=>404}
    return item_tokens if attachments.is_a?(Hash) && attachments['code'] == 404

    item_tokens << parsed_attachments(attachments)

    item_tokens
  end

  def parsed_comment(comment)
    # {
    #   "body":"@[Jane Developer](pk:26395) The problem is in method: order.merchandise_total. Its calculated from order_items.merchandise.total, but GIFT_ID is set as NON_MERCHANDISE. So the order_item (gift) is excluded from the scope.\n\nPossible solutions:\n1) Change the method calculation:\n  Instead of: @merchandise_total ||= self.order_items.merch_total\n  Change to: @merchandise_total ||= self.order_items.sum(:total)\n - But this would effect other calculations, I suppose, because this method is called from multiple places. But Im not sure if on other places is the value wrong as well.. ?\n\n2) Change the view calculation:\n  Instead of: number_to_currency @order.merchandise_total\n  Change to this: number_to_currency @order.merchandise_total + @order.gift_cards_total\n- Maybe this one is the best solution? \n\nI have created a merge request with the 2) solution. \nLet me please know if its correct. Thanks",
    #   "created_at":"2014-07-21T11:47:29+00:00",
    #   "created_by":{
    #   "first_name":"Joe",
    #   "last_name":"Developer",
    #   "created_at":"2014-07-14T17:48:02+00:00",
    #   "email":"joe.developer@devshop.com",
    #   "last_login":"2014-07-25T11:13:52+00:00",
    #   "id":26560
    # },
    #   "last_modified":"2014-07-21T11:47:30+00:00",
    #   "type":"comment",
    #   "id":901569
    # }

    return nil unless comment["body"]

    comment_body = comment["body"]
    shout_outs = comment_body.scan /@\[([^\]]+)\]\([^\)]+\)[^@]/
    if shout_outs
      comment_body.gsub!(/(@\[[^\]]+\]\([^\)]........)/) do |old_shout_out|
        new_shout_out = shout_outs.flatten.detect { |shout_out| next unless old_shout_out.include?(shout_out); MEMBER_FULL_NAME_TO_TRACKER_HANDLE[shout_out] }
        MEMBER_FULL_NAME_TO_TRACKER_HANDLE[new_shout_out]
      end
    end

    "#{comment_body} (#{normalized_full_name(comment['created_by'])} - #{normalized_date(comment['created_by'],'created_at')})"
  end

  def parsed_attachments(attachments)
    return '' if attachments.empty?

    attachments_comment = ''
    attachments.each do |attachment|
      attachments_comment << "#{attachment['name']}: #{attachment['href']}\n"
    end

    attachments_comment
  end

  def items_request(offset, limit = 100)
    # optional parameters:
    # status=someday,backlog,in-progress,completed,accepted
    # tags=pivotal
    # children=true
    # offset=0
    # limit=100
    # order_by=oldest
    HTTParty.get "https://sprint.ly/api/products/#{product_id}/items.json?status=someday,backlog,in-progress,completed,accepted&tags=pivotal&children=true&offset=#{offset}&limit=#{limit}&order_by=oldest", basic_auth: credentials
  end

  def comments_request(item_number)
    HTTParty.get "https://sprint.ly/api/products/#{product_id}/items/#{item_number}/comments.json", basic_auth: credentials
  end

  def attachments_request(item_number)
    HTTParty.get "https://sprint.ly/api/products/#{product_id}/items/#{item_number}/attachments.json", basic_auth: credentials
  end

  private

  def normalized_full_name(base_node)
    return '' unless base_node
    "#{base_node['first_name']} #{base_node['last_name']}"
  end

  def normalized_date(base_node, key)
    return '' unless base_node
    Date.parse(base_node[key]).strftime("%b %d, %Y")
  end

  def normalized_datetime(base_node, key)
    return nil unless base_node
    base_node[key]
  end

  def normalized_type(story_type)
    SPRINTLY_TO_TRACKER_TYPE_MAPPING[story_type]
  end

  def normalized_status(story_status, accepted_at)
    return 'accepted' if accepted_at
    SPRINTLY_TO_TRACKER_STATUS_MAPPING[story_status]
  end

  def normalized_score(story_status, story_score)
    if ['delivered','accepted'].include? story_status
      if SPRINTLY_TO_TRACKER_ESTIMATE_MAPPING[story_score] > -1
        SPRINTLY_TO_TRACKER_ESTIMATE_MAPPING[story_score]
      else
        2 # Any story that was accepted needs an estimate. We go with a 2 for good measure.
      end
    else
      SPRINTLY_TO_TRACKER_ESTIMATE_MAPPING[story_score]
    end
  end

  def normalized_tags(tags)
    return nil if tags.empty?
    "#{tags.join(',')}"
  end

end

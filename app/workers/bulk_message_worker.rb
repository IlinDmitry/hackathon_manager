class BulkMessageWorker
  include Sidekiq::Worker

  def perform(message_id)
    message = Message.find(message_id)
    return unless message.present? && message.status == "queued"
    message.update_attribute(:started_at, Time.now)

    recipients = self.class.build_recipients(message.recipients)

    # Ensures it takes no longer than 30 minutes to deliver all mail
    # 30 groups * 1 minute = 30 minutes
    delay_increment = 1.minute
    slice_size = [10, recipients.count / 30].max.to_int

    delay_minutes = 0.minutes
    recipients.each_slice(slice_size) do |recipient_slice|
      recipient_slice.each do |recipient|
        Mailer.delay_for(delay_minutes).bulk_message_email(message.id, recipient)
      end
      delay_minutes += delay_increment
    end

    message.update_attribute(:delivered_at, Time.now)
  end

  def self.build_recipients(recipient_types)
    recipients = Set.new
    recipient_types.each do |type|
      recipients += user_ids(type)
    end
    recipients
  end

  # rubocop:disable CyclomaticComplexity
  def self.user_ids(type)
    case type
    when "all"
      User.where(admin: false).pluck(:id)
    when "incomplete"
      User.where(admin: false).pluck(:id) - Questionnaire.pluck(:user_id)
    when "complete"
      Questionnaire.pluck(:user_id)
    when "accepted"
      Questionnaire.where(acc_status: "accepted").pluck(:user_id)
    when "denied"
      Questionnaire.where(acc_status: "denied").pluck(:user_id)
    when "waitlisted"
      Questionnaire.where(acc_status: "waitlist").pluck(:user_id)
    when "late-waitlisted"
      Questionnaire.where(acc_status: "late_waitlist").pluck(:user_id)
    when "rsvp-confirmed"
      Questionnaire.where(acc_status: "rsvp_confirmed").pluck(:user_id)
    when "rsvp-denied"
      Questionnaire.where(acc_status: "rsvp_denied").pluck(:user_id)
    when "checked-in"
      Questionnaire.where("checked_in_at IS NOT NULL").pluck(:user_id)
    when "non-checked-in"
      Questionnaire.where("(acc_status = 'accepted' OR acc_status = 'rsvp_confirmed' OR acc_status = 'rsvp_denied') AND checked_in_at IS NULL").pluck(:user_id)
    when "non-checked-in-excluding"
      Questionnaire.where("acc_status != 'accepted' AND acc_status != 'rsvp_confirmed' AND acc_status != 'rsvp_denied' AND checked_in_at IS NULL").pluck(:user_id)
    when /(.*)::(\d*)/
      user_ids_from_query(type)
    else
      raise "Unknown recipient type: #{type.inspect}"
    end
  end
  # rubocop:enable CyclomaticComplexity

  def self.user_ids_from_query(type)
    # Parse the query
    # See app/models/message_recipient_query.rb for how this works
    recipient_query = MessageRecipientQuery.parse(type)
    model = recipient_query.model

    # Build the recipients query
    case recipient_query.type
    when "bus-list"
      model.passengers.pluck(:user_id)
    when "bus-list--eligible"
      Questionnaire.joins(:school).where("schools.bus_list_id = ? AND riding_bus != 1 AND (acc_status = 'accepted' OR acc_status = 'rsvp_confirmed')", model.id).pluck(:user_id)
    when "bus-list--applied"
      Questionnaire.joins(:school).where("schools.bus_list_id = ? AND (acc_status != 'accepted' AND acc_status != 'rsvp_confirmed' AND acc_status != 'rsvp_denied')", model.id).pluck(:user_id)
    when "school"
      Questionnaire.where("school_id = ? AND (acc_status = 'rsvp_confirmed' OR acc_status = 'accepted')", model.id).pluck(:user_id)
    else
      raise "Unknown recipient query type: #{recipient_query.type.inspect} (in message recipient query: #{type.inspect}"
    end
  end
end

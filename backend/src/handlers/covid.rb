require 'dotenv/load'
require 'pdf-forms'
require 'mysql2'

require './src/util'
require './src/clients/ses'
require './src/clients/mysql'

# Process to fill Mandatory or Precautionary Quarantine Order form.
class COVIDHandler

  def initialize(submission, ses, db)
    @submission = submission

    @quarantine_pdf_template_path = "./constants/mandatory_quarantine.pdf"
    @output_folder = "/tmp"

    @submission_id_key = "UniqueID"

    @name_key = ENV.fetch("NAME_KEY", "94903913")
    @has_email_key = ENV.fetch("HAS_EMAIL_KEY", "94903922")
    @date_of_birth_key = ENV.fetch("DOB_KEY", "94903914")
    @patient_email_key = ENV.fetch("PATIENT_EMAIL_KEY", "94903923")
    @patient_address_key = ENV.fetch("PATIENT_ADDRESS_KEY", "94903924")

    @quarantine_reasons_key = ENV.fetch("REASONS_KEY", "94903915")
    @reside_with_date_key = ENV.fetch("RESIDE_WITH_DATE_KEY", "94903916")
    @close_contact_date_key = ENV.fetch("CLOSE_CONTACT_DATE_KEY", "94903917")
    @travel_date_key = ENV.fetch("TRAVEL_DATE_KEY", "94903918")
    @other_reason_date_key = ENV.fetch("OTHER_REASON_DATE_KEY", "94903919")
    @exposure_date_key = ENV.fetch("PROXIMATE_EXPOSURE_DATE_KEY", "94903920")
    @describe_key = ENV.fetch("DESCRIBE_KEY", "94903921")

    @full_name = "#{@submission[@name_key]["value"]["first"]} #{@submission[@name_key]["value"]["last"]}"

    # TODO: make this work with DLS (not urgent because requirement is approx. current time)
    local_time = Time.now.getlocal('-04:00')
    @todays_date = local_time.strftime("%B %d, %Y")
    @current_time = local_time.strftime("%I:%M %p")

    @quarantine_order_output_path = "#{@output_folder}/#{@submission[@submission_id_key]}/quarantine_order.pdf"

    @pdftk = PdfForms.new
    @ses = ses
    @db = db
  end

  def fill_quarantine_order
    quarantine_pdf_key_map = {
      "Name" => @full_name,
      "DOB" => @submission[@date_of_birth_key]["value"],
      "Email" => @submission[@patient_email_key]["value"],
      "Order Date" => @todays_date
    }
    quarantine_pdf_key_map.merge!(quarantine_reason_option)

    @pdftk.fill_form @quarantine_pdf_template_path,
                     @quarantine_order_output_path,
                     quarantine_pdf_key_map
  end

  def quarantine_reason_option
    quarantine_reason = @submission[@quarantine_reasons_key]["value"]

    case quarantine_reason
    when "Reside with a person who tested positive for, or had symptoms of Covid-19."
      {"Reside With" => "On",
       "Reside with date" => @submission[@reside_with_date_key]["value"]}
    when "Had close contact (within 6 feet) with a person who tested positive for, or had symptoms of Covid-19."
      {"Close Contact" => "On",
       "Close contact date" => @submission[@close_contact_date_key]["value"] }
    when "Were told to quarantine because you travelled internationally including cruise ship travel."
      {"Travel" => "On", "Travel Date" => @submission[@travel_date_key]["value"]}
    when "Have another reason to quarantine (i.e. you were told to quarantine by Test and Trace)."
      {"Other Reason" => "On",
       "Other Date" => @submission[@other_reason_date_key]["value"],
       "Other Reason for Quarantine" => @submission[@describe_key]["value"]}
    end
  end

  def email_documents
    text = nil
    html = nil
    to_addr = nil
    should_email = @submission[@has_email_key]["value"] == "Yes"
    if should_email
        to_addr = @submission[@patient_email_key]["value"]

        text = "Dear #{@full_name},\n\nThe Quarantine Order that you requested is attached to this email. Please sign and date on the last page. If you have any questions, please call the NYC Department of Health and Mental Hygiene Coronavirus Call Line at (855)–491–2667.\n\nSincerely,\n\nNYC Department of Health and Mental Hygiene"

        html = "Dear #{@full_name},<br><br>" +
            "The Quarantine Order that you requested is attached to this email. Please sign and date on the last page. " +
            "If you have any questions, please call the NYC Department of Health and Mental Hygiene Coronavirus Call Line at (855)–491–2667.<br><br>" +
            "Sincerely,<br>" +
            "NYC Department of Health and Mental Hygiene<br>"

    else
        to_addr = ENV.fetch("TO_ADDR_NO_EMAIL")
        patient_addr = @submission[@patient_address_key]["value"]
        text = "Hello,\n\nPlease print the attached document and mail to:\n\n#{@full_name}\n#{patient_addr["address"]}\n#{patient_addr["address2"]}\n#{patient_addr["city"]}, #{patient_addr["state"]} #{patient_addr["zip"]}\n\nSincerely,\nNYC Cityhall"
        html = "Hello,<br><br>" +
            "Please print the attached document(s) and mail to:<br><br>" +
            "#{@full_name}<br>" +
            "#{patient_addr["address"]}<br>" +
            "#{patient_addr["address2"]}<br>" +
            "#{patient_addr["city"]}, #{patient_addr["state"]} #{patient_addr["zip"]}<br><br>" +
            "Sincerely,<br>" +
            "NYC Department of Health and Mental Hygiene"
    end
    @ses.send(
        "NYC DOHMH Quarantine Order",
        text,
        html,
        to_addr,
        attachments: [@quarantine_order_output_path],
        sendername: ENV.fetch("FROM_ADDR_NAME", "NYC Department of Health and Mental Hygiene")
    )
    if not ENV.fetch("TENANCY") == "staging"
        type = "QUARANTINE"
        @db.add_submission(type, should_email)
    end
  end

  def process
    create_dir_unless_exists("#{@output_folder}/#{@submission[@submission_id_key]}")
    fill_quarantine_order
    email_documents
  end
end

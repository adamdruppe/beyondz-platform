require 'uuidtools'

class ChampionsController < ApplicationController
  layout 'public'

  before_filter :set_up_lists

  def index
  end

  before_filter :authenticate_user!, :only => [:connect, :request_contact, :contact, :fellow_survey, :fellow_survey_save]
  def connect
    # FIXME: prompt linked in access from user

    @active_requests = ChampionContact.active(current_user.id)
    @max_allowed = 2 - @active_requests.count
    if @max_allowed < 0
      @max_allowed = 0
    end

    @results = []
    @search_attempted = false

    if params[:view_all]
      @results = Champion.all
      @search_attempted = true
    end

    if params[:studies_csv]
      @search_attempted = true
      studies = params[:studies_csv].split(',').map(&:strip).reject(&:empty?)
      studies.each do |s|
        query = Champion.where("array_to_string(studies, ',') ILIKE ?","%#{s}%").where("willing_to_be_contacted = true")
        if Rails.application.secrets.smtp_override_recipient.blank?
          query = query.where("email NOT LIKE '%@bebraven.org'")
        end
        query.each do |c|
          @results << c
        end
      end
    end

    if params[:industries_csv]
      @search_attempted = true
      industries = params[:industries_csv].split(',').map(&:strip).reject(&:empty?)
      industries.each do |s|
        query = Champion.where("array_to_string(industries, ',') ILIKE ?","%#{s}%").where("willing_to_be_contacted = true")
        if Rails.application.secrets.smtp_override_recipient.blank?
          query = query.where("email NOT LIKE '%@bebraven.org'")
        end
        query.each do |c|
          @results << c
        end
      end
    end

    @results = @results.sort.uniq

    results_filtered = []

    # soooo this is O(n*m) but I am banking on the number of ChampionContacts being
    # somewhat small since we limit the amount of interactions any user is allowed to have
    # and I am expecting the query to be cached.
    @results.each do |result|
      found = false
      ChampionContact.where(:user_id => current_user.id).each do |ar|
        if result.id == ar.champion_id
          found = true
          break
        end
      end

      if !found
        results_filtered << result
      end
    end

    @results = results_filtered
  end

  def terms
  end

  def contact
    @other_active_requests = ChampionContact.active(current_user.id).where("id != ?", params[:id])
    cc = ChampionContact.find(params[:id])
    raise "wrong user" if cc.user_id != current_user.id

    @recipient = Champion.find(cc.champion_id)
    @hit = @recipient.industries.any? ? @recipient.industries.first : @recipient.studies.fist

    if params[:others]
      @others = params[:others]
    else
      @others = []
    end
  end

  def request_contact
    # the champion ids are passed by the user checking their boxes
    champion_ids = params[:champion_ids]

    ccs = []

    champion_ids.each do |cid|
      if ChampionContact.active(current_user.id).where(:champion_id => cid).any?
        ccs << ChampionContact.active(current_user.id).where(:champion_id => cid).first
        next
      end

      ccs << ChampionContact.create(
        :user_id => current_user.id,
        :champion_id => cid,
        :nonce => UUIDTools::UUID.random_create.to_s
      )
    end

    redirect_to champions_contact_path(ccs.first.id, :others => ccs[1 .. -1])
  end

  def fellow_survey
    @contact = ChampionContact.find(params[:id])
    return fellow_permission_denied if current_user.id != 1 && current_user.id != @contact.user_id
    @champion = Champion.find(@contact.champion_id)
  end

  def champion_survey
    @contact = ChampionContact.find(params[:id])
    return champion_permission_denied if !@contact.nonce.nil? && @contact.nonce != params[:nonce]
    @fellow = User.find(@contact.user_id)
  end

  def fellow_survey_save
    @contact = ChampionContact.find(params[:id])
    return fellow_permission_denied if current_user.id != 1 && current_user.id != @contact.user_id
    @contact.update_attributes(params[:champion_contact].permit(
      :champion_replied,
      :fellow_get_to_talk_to_champion,
      :why_not_talk_to_champion,
      :would_fellow_recommend_champion,
      :what_did_champion_do_well,
      :what_could_champion_improve,
      :reminder_requested,
      :inappropriate_champion_interaction,
      :fellow_comments
    ))
    if params[:champion_contact][:champion_replied] == 'true'
      @contact.reminder_requested = false
    end
    @contact.fellow_survey_answered_at = DateTime.now
    @contact.save

    if params[:champion_contact][:reminder_requested] == "true"
      @reminder_requested = true
      @reminder_email = Champion.find(@contact.champion_id).email
    end


    # check for unresponsive champion here
    if ChampionContact.where(:champion_id => @contact.champion_id, :reminder_requested => false, :champion_replied => false).joins("INNER JOIN champions ON champions.id = champion_contacts.id AND champions.willing_to_be_contacted = true").count == 2
      champ = Champion.find(@contact.champion_id)
      champ.willing_to_be_contacted = false
      champ.save

      # need to email them asking if they want to be back on the list
      Reminders.ask_champion_status(champ).deliver
    end

    end
  end

  def champion_survey_save
    @contact = ChampionContact.find(params[:id])
    return champion_permission_denied if !@contact.nonce.nil? && @contact.nonce != params[:nonce]
    @contact.update_attributes(params[:champion_contact].permit(
      :inappropriate_fellow_interaction,
      :champion_get_to_talk_to_fellow,
      :why_not_talk_to_fellow,
      :how_champion_felt_conversaion_went,
      :what_did_fellow_do_well,
      :what_could_fellow_improve,
      :champion_comments
    ))
    @contact.champion_survey_answered_at = DateTime.now
    @contact.save
  end

  def fellow_permission_denied
    render 'fellow_permission_denied', :status => :forbidden
  end

  def champion_permission_denied
    render 'champion_permission_denied', :status => :forbidden
  end

  def new
    @champion = Champion.new
  end

  def linkedin_authorize
    linkedin_connection = LinkedIn.new
    nonce = session[:oauth_linked_nonce] = SecureRandom.hex
    redirect_to linkedin_connection.authorize_url(linkedin_oauth_success_url, nonce)
  end

  def linkedin_oauth_success
    linkedin_connection = LinkedIn.new
    nonce = session.delete(:oauth_linked_nonce)
    raise Exception.new 'Wrong nonce' unless nonce == params[:state]

    if params[:error]
      # Note: if user cancels, then params[:error] == 'user_cancelled_authorize'
      flash[:error] = 'You declined LinkedIn, please use your email address to sign up.'
      Rails.logger.error("LinkedIn authorization failed. error = #{params[:error]}, error_description = #{params[:error_description]}")
      redirect_to new_champion_url(:showform => true)
      return
    end

    access_token = linkedin_connection.exchange_code_for_token(params[:code], linkedin_oauth_success_url)

    # Note: the service_user_id, service_user_name, and service_user_url are LinkedIn's data that we get
    # by calling into their API.  E.g. service_user_url maybe something like: https://www.linkedin.com/in/somelinkedinusername
    if access_token
      li_user = linkedin_connection.get_service_user_info(access_token)

      @champion = Champion.new
      @champion.first_name = li_user['first_name']
      @champion.last_name = li_user['last_name']
      @champion.email = li_user['email_address']
      @champion.company = li_user['company']
      @champion.job_title = li_user['job_title']
      @champion.linkedin_url = li_user['user_url']
      @champion.studies = li_user['majors']
      @champion.industries = li_user['industries']

      session[:linkedin_access_token] = access_token # keeping it on the server, don't even want to give this to the user
      # we might be able to pull in even more
      @linkedin_present = true
      render 'new'
    else
      Rails.logger.error('Error registering LinkedIn service for Champion. The access_token couldn\'t be retrieved using the code sent from LinkedIn')
      raise Exception.new 'Failed getting access token for LinkedIn'
    end
  end

  def create
    champion = params[:champion].permit(
      :first_name,
      :last_name,
      :email,
      :phone,
      :company,
      :job_title,
      :linkedin_url,
      :region,
      :braven_fellow,
      :braven_lc,
      :willing_to_be_contacted
    )

    # if JS is there, we'll get the csv, otherwise, it falls back to checkboxes
    if params[:industries_csv] && !params[:industries_csv].empty?
      champion[:industries] = params[:industries_csv].split(',').map(&:strip).reject(&:empty?)
    else
      champion[:industries] = params[:champion][:industries].reject(&:empty?)
    end

    if params[:studies_csv] && !params[:studies_csv].empty?
      champion[:studies] = params[:studies_csv].split(',').map(&:strip).reject(&:empty?)
    else
      champion[:studies] = params[:champion][:studies].reject(&:empty?)
    end

    was_new = false
    n = nil
    # duplicate check, if email exists, just update existing row
    existing = Champion.where(:email => champion[:email])
    if existing.any?
      n = existing.first
      n.update_attributes(champion)
    else
      n = Champion.new(champion)
      was_new = true
    end
    if !n.valid? || n.errors.any?
      @champion = n
      if session[:linkedin_access_token]
        @linkedin_present = true
      end
      render 'new'
      return
    end

    if session[:linkedin_access_token]
      n.access_token = session.delete(:linkedin_access_token)
    end

    n.save

    n.create_on_salesforce

    if was_new
      ChampionsMailer.new_champion(n).deliver
    end
  end

  def set_up_lists
    @industries = [
      'Accounting',
      'Advertising',
      'Aerospace',
      'Banking',
      'Beauty / Cosmetics',
      'Biotechnology ',
      'Business',
      'Chemical',
      'Communications',
      'Computer Engineering',
      'Computer Hardware ',
      'Education',
      'Electronics',
      'Employment / Human Resources',
      'Energy',
      'Fashion',
      'Film',
      'Financial Services',
      'Fine Arts',
      'Food & Beverage ',
      'Health',
      'Information Technology',
      'Insurance',
      'Journalism / News / Media',
      'Law',
      'Management / Strategic Consulting',
      'Manufacturing',
      'Medical Devices & Supplies',
      'Performing Arts ',
      'Pharmaceutical ',
      'Public Administration',
      'Public Relations',
      'Publishing',
      'Marketing ',
      'Real Estate ',
      'Sports ',
      'Technology ',
      'Telecommunications',
      'Tourism',
      'Transportation / Travel',
      'Writing'
    ]

    @fields = [
      'Accounting ',
      'African American Studies ',
      'African Studies ',
      'Agriculture ',
      'American Indian Studies ',
      'American Studies ',
      'Architecture ',
      'Asian American Studies ',
      'Asian Studies ',
      'Dance',
      'Visual Arts',
      'Theater',
      'Music',
      'English / Literature ',
      'Film',
      'Foreign Language ',
      'Graphic Design',
      'Philosophy ',
      'Religion ',
      'Business',
      'Marketing',
      'Actuarial Science',
      'Hospitality ',
      'Human Resources ',
      'Real Estate ',
      'Health',
      'Public Health ',
      'Medicine ',
      'Nursing ',
      'Gender Studies ',
      'Urban Studies ',
      'Latin American Studies ',
      'European Studies ',
      'Gay and Lesbian Studies ',
      'Latinx Studies ',
      'Women’s Studies ',
      'Education ',
      'Psychology ',
      'Child Development',
      'Computer Science ',
      'History ',
      'Biology ',
      'Cognitive Science ',
      'Human Biology ',
      'Diversity Studies ',
      'Marine Sciences ',
      'Maritime Studies ',
      'Math',
      'Nutrition ',
      'Sports and Fitness ',
      'Law / Legal Studies ',
      'Military ',
      'Public Administration ',
      'Social Work ',
      'Criminal Justice ',
      'Theology ',
      'Equestrian Studies ',
      'Food Science ',
      'Urban Planning',
      'Art History ',
      'Interior Design ',
      'Landscape Architecture ',
      'Chemistry ',
      'Physics ',
      'Chemical Engineering ',
      'Software Engineering ',
      'Industrial Engineering ',
      'Civil Engineering',
      'Electrical Engineering ',
      'Mechanical Engineering ',
      'Biomedical Engineering',
      'Computer Hardware Engineering',
      'Anatomy ',
      'Ecology ',
      'Genetics ',
      'Neurosciences',
      'Communications ',
      'Animation ',
      'Journalism ',
      'Information Technology  ',
      'Aerospace',
      'Geography',
      'Statistics ',
      'Environmental Studies ',
      'Astronomy ',
      'Public Relations',
      'Library Science',
      'Anthropology',
      'Economics',
      'Criminology',
      'Archaeology',
      'Cartography',
      'Political Science',
      'Sociology',
      'Construction Trades',
      'Culinary Arts',
      'Creative Writing'
    ]
  end
end

require 'nokogiri'

class LinkedIn
  def config
    a = {}
    a['api_key'] = ENV['LINKEDIN_API_KEY']
    a['secret_key'] = ENV['LINKEDIN_API_SECRET']
    a
  end

  def get_request(path, access_token)
    http = Net::HTTP.new('api.linkedin.com', 443)
    http.use_ssl = true
    # http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    request = Net::HTTP::Get.new(path)
    request['Authorization'] = "Bearer #{access_token}"
    response = http.request(request)

    response
  end

  def get_service_user_info(access_token)
    body = get_request('/v1/people/~:(id,first-name,last-name,public-profile-url,picture-url,email-address,three-past-positions,three-current-positions,industry,educations)?format=json', access_token).body
    data = JSON.parse(body)

    user = {}

    user['user_id'] = data['id']
    user['first_name'] = data['firstName']
    user['last_name'] = data['lastName']
    user['email_address'] = data['emailAddress']
    user['user_url'] = data['publicProfileUrl']
    user['majors'] = get_majors(data['educations'])
    user['industries'] = get_industries(data['threeCurrentPositions'], data['threePastPositions'])
    user['company'] = get_current_employer(data['threeCurrentPositions'])
    user['job_title'] = get_job_title(data['threeCurrentPositions'])

    user
  end

  def get_current_employer(node)
    current_employer_node = node['values'].find { |job| job['isCurrent'] == true } unless node['_total'] == 0
    current_employer_company_node = current_employer_node['company'] unless current_employer_node.nil?
    current_employer = current_employer_company_node['name'] unless current_employer_company_node.nil?
    current_employer
  end

  def get_job_title(node)
    current_employer_node = node['values'].find { |job| job['isCurrent'] == true } unless node['_total'] == 0
    job_title = current_employer_node['title'] unless current_employer_node.nil?
    job_title
  end

  def get_majors(educations_node)
    majors = []
    return majors if educations_node['_total'] == 0
    educations_node['values'].each do |n|
      majors.push(n['fieldOfStudy']) unless majors.include?(n['fieldOfStudy'])
    end
    majors
  end

  def get_industries(pn, past)
    industries = []
    if pn['_total'] != 0
      pn['values'].each do |n|
        company = n['company']
        next if company.nil?
        industries.push(company['industry']) unless industries.include?(company['industry'])
      end
    end
    if past['_total'] != 0
      past['values'].each do |n|
        company = n['company']
        next if company.nil?
        industries.push(company['industry']) unless industries.include?(company['industry'])
      end
    end

    industries
  end





  def authorize_url(return_to, nonce)
    "https://www.linkedin.com/oauth/v2/authorization?response_type=code&scope=r_emailaddress%20r_fullprofile&client_id=#{config['api_key']}&state=#{nonce}&redirect_uri=#{CGI.escape(return_to)}"
  end

  def exchange_code_for_token(code, redirect_uri)
    http = Net::HTTP.new('www.linkedin.com', 443)
    http.use_ssl = true
    # http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    request = Net::HTTP::Post.new('/oauth/v2/accessToken')
    request.set_form_data(
      'grant_type' => 'authorization_code',
      'code' => code,
      'redirect_uri' => redirect_uri,
      'client_id' => config['api_key'],
      'client_secret' => config['secret_key']
    )
    response = http.request(request)

    info = JSON.parse response.body

    info['access_token']
  end
end

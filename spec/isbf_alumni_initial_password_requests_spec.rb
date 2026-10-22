# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ISBF Alumni initial password", type: :request do
  fab!(:alumni_group) { Fabricate(:group, name: "alumni") }
  fab!(:user)
  let(:password) { "test-only-#{SecureRandom.hex(16)}" }
  let!(:application) do
    IsbfAlumni::Application.create!(
      email: user.email, email_verified_at: Time.current, status: "registered",
      user: user, registered_at: Time.current,
    )
  end

  before do
    SiteSetting.isbf_alumni_enabled = true
    SiteSetting.isbf_alumni_group_name = alumni_group.name
    SiteSetting.enable_local_logins = true
    SiteSetting.enable_discourse_connect = false
    alumni_group.add(user)
    user.user_password&.destroy!
    user.reload
    sign_in(user)
  end

  def set_password(value = password, **extra)
    put "/isbf/alumni/initial-password.json", params: { password: value, **extra }
  end

  it "sets a native password and keeps the current browser authenticated" do
    set_password
    expect(response.status).to eq(200), response.body
    expect(user.reload.confirm_password?(password)).to eq(true)
    get "/session/current.json"
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.dig("current_user", "id")).to eq(user.id)
    expect(response.body).not_to include(password)
    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.post "/session.json", params: { login: user.username, password: password }
    expect(browser.response.status).to eq(200), browser.response.body
    expect(browser.response.parsed_body.dig("user", "id")).to eq(user.id)
  end

  it "accepts the same retry without replacing the stored hash and conflicts on another password" do
    set_password
    expect(response.status).to eq(200), response.body
    original = user.reload.user_password.attributes.slice("password_hash", "password_salt")
    set_password
    expect(response.status).to eq(200), response.body
    expect(user.reload.user_password.attributes.slice("password_hash", "password_salt")).to eq(original)
    set_password("test-only-different-#{SecureRandom.hex(16)}")
    expect(response.status).to eq(409), response.body
    expect(user.reload.user_password.attributes.slice("password_hash", "password_salt")).to eq(original)
  end

  it "applies native weak password policy and rolls back failed validation" do
    set_password("a")
    expect(response.status).to eq(422), response.body
    expect(user.reload.has_password?).to eq(false)
    set_password
    expect(response.status).to eq(200), response.body
    expect(user.reload.confirm_password?(password)).to eq(true)
  end

  [nil, [], {}, "", "a" * 201].each do |invalid|
    it "rejects invalid password input #{invalid.class} without storing it" do
      set_password(invalid)
      expect(response.status).to eq(422), response.body
      expect(user.reload.has_password?).to eq(false)
    end
  end

  it "never selects a user from request parameters" do
    other = Fabricate(:user)
    previous_hash = other.user_password.password_hash
    set_password(password, user_id: other.id)
    expect(response.status).to eq(200), response.body
    expect(user.reload.confirm_password?(password)).to eq(true)
    expect(other.reload.user_password.password_hash).to eq(previous_hash)
  end

  {
    unapproved_application: { status: "approved" },
    mismatched_email: { email: "different-owner@example.com" },
    unverified_email: { email_verified_at: nil },
    missing_registration: { registered_at: nil },
    other_owner: { user_id: nil },
  }.each do |name, attributes|
    it "rejects #{name}" do
      application.update!(attributes)
      set_password
      expect(response.status).to eq(403), response.body
      expect(user.reload.has_password?).to eq(false)
    end
  end

  it "rejects an account without its Alumni membership" do
    alumni_group.remove(user)
    set_password
    expect(response.status).to eq(403), response.body
    expect(user.reload.has_password?).to eq(false)
  end

  it "rejects a user without an application" do
    application.destroy!
    set_password
    expect(response.status).to eq(403), response.body
  end

  it "rejects an anonymous direct write" do
    delete "/session/#{user.username}.json"
    set_password
    expect(response.status).to eq(403), response.body
    expect(user.reload.has_password?).to eq(false)
  end

  it "rejects an inactive or unapproved account" do
    SiteSetting.must_approve_users = true
    user.update!(approved: false)
    set_password
    expect(response.status).to eq(403), response.body
    expect(user.reload.has_password?).to eq(false)
  end

  it "uses native forum access when manual account approval is disabled" do
    SiteSetting.must_approve_users = false
    SiteSetting.invite_only = false
    user.update!(approved: false)
    set_password
    expect(response.status).to eq(200), response.body
    expect(user.reload.confirm_password?(password)).to eq(true)
  end

  it "rejects a suspended account" do
    user.update!(suspended_at: Time.current, suspended_till: 1.day.from_now)
    set_password
    expect(response.status).to eq(403), response.body
    expect(user.reload.has_password?).to eq(false)
  end

  it "works after new Alumni applications close" do
    SiteSetting.isbf_alumni_registration_enabled = false
    set_password
    expect(response.status).to eq(200), response.body
    expect(user.reload.confirm_password?(password)).to eq(true)
  end

  it "rejects a disabled plugin" do
    SiteSetting.isbf_alumni_enabled = false
    set_password
    expect(response.status).to be_in([403, 404])
    expect(user.reload.has_password?).to eq(false)
  end

  it "rejects a direct write without a valid native CSRF token" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    set_password
    expect(response.status).to eq(403), response.body
    expect(user.reload.has_password?).to eq(false)
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  it "applies the current-user rate limit to retries too" do
    RateLimiter.enable
    10.times do
      set_password("a")
      expect(response.status).to eq(422), response.body
    end
    set_password
    expect(response.status).to eq(429), response.body
    expect(user.reload.has_password?).to eq(false)
  ensure
    RateLimiter.disable
  end
end

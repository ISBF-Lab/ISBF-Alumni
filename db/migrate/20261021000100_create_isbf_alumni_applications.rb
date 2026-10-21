# frozen_string_literal: true

class CreateIsbfAlumniApplications < ActiveRecord::Migration[7.2]
  def change
    create_table :isbf_alumni_applications do |t|
      t.string :email, null: false, limit: 254
      t.string :status, null: false, default: "draft"
      t.datetime :email_verified_at, null: false
      t.string :real_name, limit: 80
      t.integer :graduation_year
      t.jsonb :profile, null: false, default: {}
      t.jsonb :proofs, null: false, default: []
      t.jsonb :submitted_proof_ids, null: false, default: []
      t.jsonb :submissions, null: false, default: []
      t.bigint :reviewable_id
      t.bigint :invite_id
      t.integer :user_id
      t.integer :reviewed_by_id
      t.datetime :submitted_at
      t.datetime :reviewed_at
      t.datetime :registered_at
      t.text :rejection_reason
      t.integer :mail_version, null: false, default: 0
      t.string :mail_status, null: false, default: "none"
      t.datetime :last_mailed_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :isbf_alumni_applications, :email, unique: true
    add_index :isbf_alumni_applications, :invite_id, unique: true
    add_index :isbf_alumni_applications, :user_id, unique: true
    add_index :isbf_alumni_applications, :reviewable_id, unique: true
    add_index :isbf_alumni_applications, :proofs, using: :gin
    add_foreign_key :isbf_alumni_applications, :invites, on_delete: :nullify
    add_foreign_key :isbf_alumni_applications, :users, on_delete: :nullify
    add_foreign_key :isbf_alumni_applications, :users, column: :reviewed_by_id, on_delete: :nullify
    add_foreign_key :isbf_alumni_applications, :reviewables, on_delete: :nullify
  end
end

#!/usr/bin/env ruby
# Reproduction: a Campaign Deputy person's `id` changes when the record is updated.
# `legacyId` stays the same, and GET /v1/people/{old id} starts returning 204 No Content.
#
# The new `id` is a KSUID whose embedded timestamp equals the record's lastUpdatedOnUTC,
# i.e. the id is re-minted on every update.
#
# Usage:
#   ruby repro.rb <person_id>            snapshot the person, then wait (up to 10 min) for it to be
#                                        edited (e.g. in the Campaign Deputy web UI) and report
#   ruby repro.rb <person_id> --api      same, but perform the edit via POST /v1/people
#   ruby repro.rb --api                  fully self-contained: create a fresh person via PUT /v1/people,
#                                        then edit it via POST /v1/people
#   ruby repro.rb --decode <id> [...]    print the timestamp embedded in KSUID ids
#
# Reads keys from .env next to this file: CAMPAIGN_DEPUTY_KEY for reads,
# FULL_PERMISSIONS_CAMPAIGN_DEPUTY_API_KEY for writes (--api).
require "net/http"
require "json"
require "uri"
require "time"

$stdout.sync = true

BASE = "https://us.api.campaigndeputy.app"
KSUID_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
KSUID_EPOCH = 1_400_000_000

def ksuid_time(id)
  n = id.chars.reduce(0) { |acc, c| acc * 62 + KSUID_ALPHABET.index(c) }
  Time.at((n >> 128) + KSUID_EPOCH).utc
end

# GET /v1/people/{id} omits the trailing Z that GET /v1/peoples includes.
def utc(ts) = Time.parse(ts.end_with?("Z") ? ts : "#{ts}Z")

def load_key(name)
  File.readlines(File.join(__dir__, ".env")).each do |line|
    k, v = line.strip.split("=", 2)
    return v.delete_prefix('"').delete_suffix('"') if k == name
  end
  abort "#{name} not found in .env"
end

class DeputyClient
  def initialize(key)
    @key = key
  end

  def get(path, params = {}) = request(Net::HTTP::Get, path, params: params)
  def put(path, body)        = request(Net::HTTP::Put, path, body: body)
  def post(path, body)       = request(Net::HTTP::Post, path, body: body)

  def person(id)
    code, body = get("/v1/people/#{id}")
    [code, code == 200 ? body["data"] : nil]
  end

  # Scan /v1/peoples (most recently updated first) for the record with this legacyId.
  def find_by_legacy_id(legacy_id, max_pages: 5)
    key = nil
    max_pages.times do
      params = { sortKey: "lastupdated" }
      params[:lastEvaluatedKey] = key if key
      _, body = get("/v1/peoples", params)
      hit = body["data"].find { |p| p["legacyId"] == legacy_id }
      return hit if hit
      key = body.dig("metadata", "lastEvaluatedKey")
      break unless key
    end
    nil
  end

  private

  def request(klass, path, params: {}, body: nil)
    uri = URI(BASE + path)
    uri.query = URI.encode_www_form(params) unless params.empty?
    req = klass.new(uri)
    req["Authorization"] = "Bearer #{@key}"
    req["Accept"] = "application/json"
    if body
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
    end
    attempts = 0
    begin
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    rescue OpenSSL::SSL::SSLError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
      attempts += 1
      raise if attempts > 3
      puts "  (retrying after #{e.class})"
      sleep 2
      retry
    end
    parsed = res.body.to_s.empty? ? nil : (JSON.parse(res.body) rescue res.body)
    puts "  #{Time.now.utc.strftime('%H:%M:%S')}  #{klass::METHOD} #{uri.request_uri} -> #{res.code}"
    [res.code.to_i, parsed]
  end
end

def show(label, p)
  puts "#{label}:"
  puts JSON.pretty_generate(p.slice(*%w[id legacyId name primaryEmailAddress createOnUTC lastUpdatedOnUTC]))
    .gsub(/^/, "    ")
  puts "    (id's embedded KSUID timestamp: #{ksuid_time(p['id']).iso8601})"
end

if ARGV.first == "--decode"
  ARGV.drop(1).each { |id| puts "#{id}  #{ksuid_time(id).iso8601}" }
  exit
end

api = ARGV.include?("--api")
original_id = ARGV.find { |a| !a.start_with?("--") }
abort "usage: ruby repro.rb <person_id> [--api] | ruby repro.rb --api" unless original_id || api
client = DeputyClient.new(load_key("CAMPAIGN_DEPUTY_KEY"))
writer = DeputyClient.new(load_key("FULL_PERMISSIONS_CAMPAIGN_DEPUTY_API_KEY")) if api

unless original_id
  tag = Time.now.utc.strftime("%Y%m%d%H%M%S")
  puts "== 0. Create a fresh person via PUT /v1/people"
  code, created = writer.put("/v1/people", {
    name: { givenName: "IdProbe", familyName: "Alpha" },
    primaryEmailAddress: "idprobe-#{tag}@example.com",
  })
  abort "create failed (#{code}): #{created.inspect}" unless code == 200
  puts "  response: #{created.to_json}"
  # Spec says this returns a Person; it actually returns {"data":{"personId":...}}.
  original_id = created.dig("data", "personId") || created["id"]
  # The id "might not be available immediately as we process the record" (API docs).
  sleep 5
end

puts "== 1. Snapshot person #{original_id}"
code, before = nil
12.times do
  code, before = client.person(original_id)
  break if before
  sleep 5
end
abort "GET returned #{code}; need a currently-valid id" unless before
show("  before", before)
legacy_id = before["legacyId"]

if api && !ARGV.include?("--no-update")
  new_family = "#{before.dig('name', 'familyName')}X"
  puts "\n== 2. Update familyName -> #{new_family.inspect} via POST /v1/people"
  code, body = writer.post("/v1/people", {
    person: { name: before["name"].merge("familyName" => new_family),
              primaryEmailAddress: before["primaryEmailAddress"] },
    options: { matchOnEmail: true },
  })
  abort "update rejected (#{code}): #{body.inspect}" unless code.between?(200, 299)
  puts "  response: #{body.inspect}"
else
  puts "\n== 2. Now edit this person in the Campaign Deputy UI (e.g. change the last name)."
end

puts "\n== 3. Waiting for lastUpdatedOnUTC to change (looking up by legacyId #{legacy_id})"
after = nil
120.times do
  sleep 5
  current = client.find_by_legacy_id(legacy_id)
  if current && utc(current["lastUpdatedOnUTC"]) != utc(before["lastUpdatedOnUTC"])
    after = current
    break
  end
end
abort "no update observed within 10 minutes" unless after

puts "\n== 4. Re-fetch by the ORIGINAL id and by the new id"
old_code, _ = client.person(original_id)
new_code, _ = client.person(after["id"])

puts "\n== RESULT"
show("  before", before)
show("  after", after)
puts "  GET /v1/people/#{original_id} (original id) -> #{old_code}"
puts "  GET /v1/people/#{after['id']} (new id)      -> #{new_code}"
if after["id"] != original_id
  puts "\n  REPRODUCED: updating the record changed its id " \
       "#{original_id} -> #{after['id']}; legacyId #{legacy_id} unchanged; old id now returns #{old_code}."
else
  puts "\n  Not reproduced: id unchanged after update."
end

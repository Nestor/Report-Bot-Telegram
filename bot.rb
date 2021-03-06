begin
  require 'telegram/bot'
  require 'colorize'
  require 'open-uri'
  require 'json'
  require 'openssl'
  require 'open3'
  require 'steam-condenser'
  require 'sqlite3'
  require 'thwait'
rescue LoadError => e
  puts "MISSING DEPENDENCIES! (#{e.message})"
  puts "run 'gem install telegram-bot-ruby colorize steam-condenser sqlite3' to install them."
  puts ""
  puts "If the SQLite installation fails, run 'sudo apt-get install ruby-dev sqlite3 sqlite3-dev libsqlite3-dev' and repeat the command above"
  puts ""
  exit
end

trap("INT") {
  puts "Closing..."
  exit
}

def decode_sharecode(sharecode)
  dictionary = "ABCDEFGHJKLMNOPQRSTUVWXYZabcdefhijkmnopqrstuvwxyz23456789".freeze
  dictionary_length = dictionary.length.freeze
  sharecode = sharecode.dup.gsub(/CSGO|\-/, '')

  result = [0] * 18

  sharecode.chars.reverse.each_with_index do |char, index|
    addval = dictionary.index(char)

    tmp    = [0] * 18

    carry, v = 0, 0
    17.downto(0).each do |t|
      carry = 0
      t.downto(0).each do |s|
        if t - s == 0
          v = tmp[s] + result[t] * 57
        else
          v = 0
        end

        v      = v + carry
        carry  = v >> 8
        tmp[s] = v & 0xFF
      end
    end

    result = tmp

    carry  = 0
    17.downto(0).each do |t|
      if t == 17
        v = result[t] + addval
      else
        v = result[t]
      end

      v         = v + carry
      carry     = v >> 8
      result[t] = v & 0xFF
    end
  end

  result = result.pack('C*')

  io = StringIO.new(result)

  return io.read(8).unpack("C*").each_with_index.reduce(0) do |sum, (byte, index)|
    sum + byte * (256 ** index)
  end
end

def log_timestamp
  time = Time.now.strftime("%d.%m.%Y %H:%M:%S")
  return "[#{time}]".black.on_white
end

def log(message)
  puts "#{log_timestamp}" + " " + message
end

$VERBOSE = nil
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

users = File.read('users.txt').split("\n") rescue []
config = JSON.parse(File.read('config.json').split("\n").join(""))

$accounts = Array.new
$usernames = Array.new
$passwords = Array.new
$steamguard_temp = Hash.new
$bancheck_last = "Never"

File.read('accounts.txt').split("\n").each do |account|
  account = account.chomp.split(":")
  username = account[0]
  password = account[1]
  lastreport = account[2].nil? ? 0 : account[2].to_i
  lastcommend = account[3].nil? ? 0 : account[3].to_i

  account = [username, password, lastreport, lastcommend]
  $accounts << account
  $usernames << username
  $passwords << password
end

$no_usernames = config["no-usernames"]

def tg_prepare(string)
  string = string.encode(Encoding.find('ASCII'), {:invalid => :replace, :undef => :replace, :replace => '', :universal_newline => true})
  if $no_usernames
    i = 0
    $usernames.each do |username|
      i += 1
      string = string.gsub(username, "account-#{i.to_s}")
    end
  end
  $passwords.each do |password|
    string = string.gsub(password, "***")
  end
  return string
end

def update_accounts
  file = File.open('accounts.txt', 'w')
  $accounts.each do |account|
    file << account.join(":")
    file << "\n"
  end
  file.close
end

def set_cooldown(username, type)
  new_accounts = Array.new
  $accounts.each do |account|
    if account[0] == username
      if type == 0
        account[2] = Time.now.to_i
      else
        account[3] = Time.now.to_i
      end
    end
    new_accounts << account
  end
  $accounts = new_accounts
end

def get_accounts(cooldown, type)
  possible_accounts = []
  $accounts.each do |account|
    if type == 0
      if Time.now.to_i > account[2] + cooldown
        possible_accounts << [account[0], account[1]]
      end
    else
      if Time.now.to_i > account[3] + cooldown
        possible_accounts << [account[0], account[1]]
      end
    end
  end
  return possible_accounts
end

log "Starting CSGO Telegram ReportBot v1.2 by sapphyrus..."
log "We currently have #{$accounts.length} account(s) and #{users.length} user(s)!"
log "Credits to luk1337, askwrite and seishun!"

update_accounts

if config['token'].empty?
  log "Telegram Token not set! Message @botfather to get one!".red
  exit
end

node_check, status = Open3.capture2e("node ./vapor-report/report.js")

if node_check.chomp == "Usage: node report.js [username] [password] [steamid] [(steamguard)]"
  log "vapor-report seems to be working!".green
elsif node_check.include? "Cannot find module"
  log "Installing vapor-report's dependencies..."
  install_dependencies = `cd vapor-report && npm install`
  node_check, status = Open3.capture2e("node ./vapor-report/report.js")
  if node_check.chomp == "Usage: node report.js [username] [password] [steamid]"
    log "Installation successful!"
  else
    puts install_dependencies.to_s
    log "Installation failed!"
    exit
  end
else
  log "NodeJS not installed!".red
  exit
end

$db = SQLite3::Database.new "reports.sqlite"
$db.execute "
  create table IF NOT EXISTS reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    steamid TEXT,
    nickname TEXT,
    reported_by TEXT,
    banned INT(1)
  );
"

Thread.abort_on_exception = true
if config["ow-check"]
  if config["steam-api-key"].empty?
    log "Steam API-Key not set! Can't start OW-Check".red
  else
    begin
      steamstatus = JSON.parse(open("https://api.steampowered.com/ICSGOServers_730/GetGameServersStatus/v1/?key=#{config['steam-api-key']}").read)["result"]
    rescue
      log "Invalid Steam API-Key!".red
    end
    if !steamstatus.nil?
      log "Steam API seems to be working!".green
      Thread.new do
        while true
          begin
            $bancheck_last = Time.now.strftime("%d.%m.%Y %T")
            @accounts = Array.new
            $db.execute("SELECT * FROM reports WHERE banned = 0 GROUP BY steamid ORDER BY id DESC LIMIT 50") do |row|
              @accounts << [row[0], row[1], row[1], row[3], row[4]]
            end
            @accounts.each do |account|
              #puts "Checking bans for #{account.inspect}"
              @steamids = account[1].to_s
              @result = JSON.parse(open("http://api.steampowered.com/ISteamUser/GetPlayerBans/v1/?key=#{config['steam-api-key']}&steamids=#{@steamids}").read)["players"][0]
              if @result["NumberOfGameBans"] >= 1
                $db.execute("UPDATE reports SET banned = 1 WHERE steamid = ?", [account[1]])
                if account[3].to_i != 0
                  log "#{account[0]} has been banned. Notifying #{account[3]}"
                  Telegram::Bot::Client.run(config['token']) do |bot| #TODO: Müsste besser gehen, ohne dass sich der Bot neu einloggen muss
                    bot.api.send_message(chat_id: account[3].to_i, parse_mode: "Markdown", text: "[#{account[1]}](https://steamcommunity.com/profiles/#{account[1]}) has been OW banned!")
                  end
                else
                  log "'#{account[1]}' (#{account[0]}) has been banned."
                end
              end
            end
          rescue => e
            log "Error occurred while running ban check: " + e.message + " " + e.backtrace.inspect
          end
          sleep 60
        end
      end
    end
  end
end

begin
  Telegram::Bot::Client.run(config['token']) do |bot|
    bot.listen do |message|
      begin
        if !message.text.nil?
          if message.text.start_with? "/"
            args = message.text.split(" ")
            is_user = config["public"] ? true : users.include?(message.chat.id.to_s)
            log "New message from '" + message.chat.id.to_s + "' (is user: #{is_user}): " + args.inspect
            case args[0]
            when "/start"
              bot.api.send_message(chat_id: message.chat.id, text: "Welcome to #{config['name']}! Your ChatID is " + message.chat.id.to_s)
              if users.empty?
                users = [message.chat.id.to_s]
                f = File.open("users.txt", "w")
                f << (users.join("\n") + "\n")
                f.close
                bot.api.send_message(chat_id: message.chat.id, text: "You have been added as your bot's first user. To add more users, open users.txt and add the ChatID!")
              end
            when "/steamguard"
              if is_user
                if args.length == 3
                  begin
                    if $steamguard_temp[args[1]] == 0
                      $steamguard_temp[args[1]] = args[2]
                      bot.api.send_message(chat_id: message.chat.id, text: "Steamguard set.")
                    else
                      throw "SteamguardNotRequired"
                    end
                  rescue
                    bot.api.send_message(chat_id: message.chat.id, text: "Account not found or no SteamGuard required")
                  end
                end
              end
              #todo: /about command
              #when "/about"
              #  bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: "This bot is using ")
              #
              #todo: /stats command with ban rate, money lost, etc
              #
              #todo: /commend [steamid] [amount]
            when "/report"
              if is_user
                if args.length == 2 or args.length == 3
                  steamid = args[1].gsub("https://", "").gsub("http://", "").gsub("steamcommunity.com/id/", "").gsub("steamcommunity.com/profiles/", "").chomp("/")
                  begin
                    if steamid.to_i.to_s == steamid
                      steamid = steamid.to_i
                      throw "Invalid ID64 (Needs to start with 765)" unless steamid.to_s[0..2] == "765"
                      throw "Invalid ID64 (Needs to be bigger than 1 as id3)" unless steamid > 76561197960265728
                    else
                      result = JSON.parse(open("http://api.steampowered.com/ISteamUser/ResolveVanityURL/v0001/?key=#{config['steam-api-key']}&vanityurl=#{steamid}").read)["response"]
                      throw "Invalid VanityURL" if result["success"] != 1
                      steamid = result["steamid"].to_i
                    end

                    result = JSON.parse(open("http://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002/?key=#{config['steam-api-key']}&steamids=#{steamid.to_s}").read)["response"]
                    throw "Profile not Found" if result["players"].empty?
                    steamid = result["players"][0]["steamid"].to_i.to_s
                  rescue StandardError
                    bot.api.send_message(chat_id: message.chat.id, text: "Couldn't fetch profile. Check if the URL/SteamID is correct. (Accepted Formats: ID64, Profile Link)")
                    steamid = nil
                  end
                  if !steamid.nil?
                    if args.length == 2
                      bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: "Reportbotting [#{steamid}](https://steamcommunity.com/profiles/#{steamid})!")
                    else
                      if args[2].to_i.to_s == args[2] && args[2].length == 19
                        matchid = args[2]
                      else
                        begin
                          matchid = decode_sharecode(args[2].gsub("steam://rungame/730/76561202255233023/+csgo_download_match%20", "")).to_s
                        rescue
                          bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: "Invalid MatchID/Sharecode!")
                        end
                      end
                      bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: "Reportbotting [#{steamid}](https://steamcommunity.com/profiles/#{steamid}) with matchid #{matchid}!")
                    end
                    accounts_report = get_accounts(config["cooldown"], 0)[0..config["default-reports"]-1]
                    if accounts_report.length != config["default-reports"]
                      bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: "Not enough reports left. Try decreasing the default amount.")
                    elsif accounts_report.length == 0
                      bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: "No accounts found.")
                    else
                      Thread.new do
                        begin
                          threads = []
                          `node ./vapor-report/protos/updater.js`
                          Dir.mkdir("data") unless File.directory? "data"
                          accounts_report.each do |account|
                            threads << Thread.new do
                              begin
                                set_cooldown(account[0], 0)
                                if args.length == 2
                                  cmd = "node ./vapor-report/report.js #{account[0]} #{account[1]} #{steamid}"
                                else
                                  cmd = "node ./vapor-report/report_matchid.js #{account[0]} #{account[1]} #{steamid} #{matchid}"
                                end
                                code = nil
                                begin
                                  cmd = cmd + " " + code.to_s unless code == 0
                                  log("[#{account[0]}] running '" + tg_prepare(cmd) + "'")
                                  Open3.popen3(cmd) do |stdin, stdout, stderr, thread|
                                    while !(raw_line = stdout.gets).nil?
                                      log("[#{account[0]}] - " + tg_prepare(raw_line))
                                      if raw_line.include? "SteamGuardRequired"
                                        #if raw_line.chomp.include? "Invalid"
                                        throw "SteamguardRequired"
                                      else
                                        bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: tg_prepare("*[#{account[0]}]* - #{raw_line}")) unless raw_line.length <= 2
                                      end
                                    end
                                  end
                                rescue UncaughtThrowError => e
                                  $steamguard_temp[account[0]] = 0
                                  bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: tg_prepare("*[#{account[0]}]* - Steam Guard required! Run /steamguard #{account[0]} CODE to send the report"))
                                  60.times do |i|
                                    sleep 2 if $steamguard_temp[account[0]] == 0
                                  end
                                  code = $steamguard_temp[account[0]]
                                  if code == 0
                                    log "Failed to get steamguard code in 2 minutes, continuing."
                                    bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: tg_prepare("*[#{account[0]}]* - Failed to get SteamGuard code in 2 minutes."))
                                  else
                                    log "Got steamguard on #{account[0]}: #{code.to_s}, re-running"
                                    retry
                                    $steamguard_temp[account[0]] = nil
                                  end
                                end
                              rescue => e
                                bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: tg_prepare("*[#{account[0]}]* - Failed to send report. Check console for more details"))
                                log "Error occurred while sending report: '" + message.text + "'" + ": " + e.message + " " + e.backtrace.inspect
                              end
                            end
                            sleep 0.1
                          end
                          update_accounts
                          nickname = steamid.to_s #todo: nickname
                          $db.execute("INSERT INTO reports (steamid, nickname, reported_by, banned) VALUES (?, ?, ?, ?)", [steamid.to_s, tg_prepare(nickname), message.chat.id.to_s, 0])
                          ThreadsWait.all_waits(*threads)
                          bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: "#{threads.length.to_s} reports sent to [#{steamid}](https://steamcommunity.com/profiles/#{steamid})! You will receive a notification if he gets banned.")
                        rescue => e
                          bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: tg_prepare("Failed to send reports. Check console for more details"))
                          log "Error occurred while sending reports: '" + message.text + "'" + ": " + e.message + " " + e.backtrace.inspect
                        end
                      end
                    end
                  end
                else
                  bot.api.send_message(chat_id: message.chat.id, text: "Usage: /report (SteamID/url)")
                end
              else
                bot.api.send_message(chat_id: message.chat.id, text: "You're not allowed to use this!")
              end
            when "/ammo"
              if is_user
                bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: "Reports left: *#{get_accounts(config["cooldown"], 0).length.to_s}*\nCommends left: *#{get_accounts(config["cooldown"], 1).length.to_s}*")
              end
            when "/reports"
              if is_user
                text = "Latest reports (Limited to 15 entries):\n"
                $db.execute("SELECT * FROM reports ORDER BY id DESC LIMIT 15") do |row|
                  if config["ow-check"]
                    banned = ""
                    banned = " (banned)" if row[4] == 1
                    text = text + "[#{row[0].to_s} - #{row[1]}](https://steamcommunity.com/profiles/#{row[1]})#{banned}\n"
                  else
                    text = text + "[#{row[0].to_s} - #{row[1]}](https://steamcommunity.com/profiles/#{row[1]})\n"
                  end
                end
                bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: tg_prepare(text))
              end
            when "/bans"
              if is_user
                if config["ow-check"]
                  header = "Latest bans (Limited to 15 entries):\n"
                  text = header
                  $db.execute("SELECT * FROM reports WHERE banned = 1 GROUP BY steamid ORDER BY id DESC LIMIT 15") do |row|
                    text = text + "[#{row[0].to_s} - #{row[1]}](https://steamcommunity.com/profiles/#{row[1]})\n"
                  end
                  if text == header
                    text = header + "No bans yet :("
                  end
                  text = text + "\nLast Check: " + $bancheck_last rescue text
                  bot.api.send_message(chat_id: message.chat.id, parse_mode: "Markdown", text: tg_prepare(text))
                else
                  bot.api.send_message(chat_id: message.chat.id, text: "Enable the OW-Check to use this command!")
                end
              else
                bot.api.send_message(chat_id: message.chat.id, text: "Unknown command.")
              end
            end
          end
        end
      rescue StandardError => e
        log "Error occurred while handling message: '" + message.text + "'" + ": " + e.message + " " + e.backtrace.inspect
        log "Please report this to @sapphyrus!"
      end
    end
  end

rescue StandardError => e
  log "Error occurred while running telegram bot: " + e.message + " " + e.backtrace.inspect
  log "This may have something todo with the Telegram API going down, restarting in 10s"
  sleep 10
  retry
end

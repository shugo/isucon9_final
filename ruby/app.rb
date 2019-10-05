require 'json'
require 'openssl'
require 'uri'
require 'net/http'
require 'securerandom'
require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'

require './utils'

module Isutrain
  class App < Sinatra::Base
    include Utils

    class Error < StandardError; end
    class ErrorNoRows < StandardError; end

    configure :development do
      require 'sinatra/reloader'

      register Sinatra::Reloader
      also_reload './utils.rb'
    end

    # ロガー
    require 'sinatra/custom_logger'
    require 'logger'
    helpers Sinatra::CustomLogger
    configure :development, :production do
      log_path = "#{__dir__}/log/#{environment}.log"
      STDOUT.reopen(log_path, "a")
      #logger = Logger.new(File.open(log_path, 'a'))
      logger = Logger.new($stdout) #File.open(log_path, 'a'))
      logger.level = Logger::DEBUG if development?
      set :logger, logger
      use Rack::CommonLogger, logger
    end

    set :protection, false
    set :show_exceptions, false
    set :session_secret, 'tagomoris'
    set :sessions, key: 'session_isutrain', expire_after: 3600

    ALL_SEATS = []
    SEAT_COUNTS = {}
    ALL_STATIONS = []

    helpers do
      def db
        Thread.current[:db] ||= Mysql2::Client.new(
          host: ENV['MYSQL_HOSTNAME'] || '127.0.0.1',
          port: ENV['MYSQL_PORT'] || '3306',
          database: ENV['MYSQL_USER'] || 'isutrain',
          username: ENV['MYSQL_DATABASE'] || 'isutrain',
          password: ENV['MYSQL_PASSWORD'] || 'isutrain',
          charset: 'utf8mb4',
          database_timezone: :local,
          cast_booleans: true,
          symbolize_keys: true,
          reconnect: true,
        )
      end

      def all_seats
        if ALL_SEATS.empty?
          ALL_SEATS.replace(db.xquery('SELECT * FROM `seat_master`').to_a)
        end
        ALL_SEATS
      end

      def seat_counts
        if SEAT_COUNTS.empty?
          result = db.xquery('SELECT train_class, seat_class, is_smoking_seat, COUNT(train_class) AS seat_count FROM `seat_master` GROUP BY train_class, seat_class, is_smoking_seat')
          result.each do |seat|
            SEAT_COUNTS[seat[:train_class], seat[:seat_class], seat[:is_smoking_seat]] = seat[:seat_count]
          end
        end
        SEAT_COUNTS
      end

      def all_stations
        if ALL_STATIONS.empty?
          ALL_STATIONS.replace(db.xquery("SELECT * FROM `station_master`").to_a)
        end
        ALL_STATIONS
      end

      def get_user
        user_id = session[:user_id]

        return nil, 401, 'no session' if user_id.nil?

        user = db.xquery(
          'SELECT * FROM `users` WHERE `id` = ?',
          user_id,
        ).first

        return nil, 401, "user not found #{user_id}" if user.nil?

        [user, 200, '']
      end

      def get_distance_fare(orig_to_dest_distance)
        distance_fare_list = db.query(
          'SELECT `distance`, `fare` FROM `distance_fare_master` ORDER BY `distance`',
        )

        last_distance = 0.0
        last_fare = 0

        distance_fare_list.each do |distance_fare|
          puts "#{orig_to_dest_distance} #{distance_fare[:distance]} #{distance_fare[:fare]}"

          break if last_distance < orig_to_dest_distance && orig_to_dest_distance < distance_fare[:distance]

          last_distance = distance_fare[:distance]
          last_fare = distance_fare[:fare]
        end

        last_fare
      end

      def fare_calc(date, dep_station, dest_station, train_class, seat_class)
        # 料金計算メモ
        # 距離運賃(円) * 期間倍率(繁忙期なら2倍等) * 車両クラス倍率(急行・各停等) * 座席クラス倍率(プレミアム・指定席・自由席)

        from_station = db.xquery(
          'SELECT * FROM `station_master` WHERE `id` = ?',
          dep_station,
        ).first

        raise ErrorNoRows if from_station.nil?

        to_station = db.xquery(
          'SELECT * FROM `station_master` WHERE `id` = ?',
          dest_station,
        ).first

        raise ErrorNoRows if to_station.nil?

        puts "distance #{(to_station[:distance] - from_station[:distance]).abs}"

        dist_fare = get_distance_fare((to_station[:distance] - from_station[:distance]).abs)
        puts "distFare #{dist_fare}"

        # 期間・車両・座席クラス倍率
        fare_list = db.xquery(
          'SELECT * FROM `fare_master` WHERE `train_class` = ? AND `seat_class` = ? ORDER BY `start_date`',
          train_class,
          seat_class,
        )

        raise Error, 'fare_master does not exists' if fare_list.to_a.length.zero?

        selected_fare = fare_list.first

        date = Date.new(date.year, date.month, date.day)
        fare_list.each do |fare|
          start_date = Date.new(fare[:start_date].year, fare[:start_date].month, fare[:start_date].day)

          if start_date <= date
            puts "#{fare[:start_date]} #{fare[:fare_multiplier]}"
            selected_fare = fare
          end
        end

        puts '%%%%%%%%%%%%%%%%%%%'

        (dist_fare * selected_fare[:fare_multiplier]).floor
      end

      def make_reservation_response(reservation)
        departure = db.xquery(
          'SELECT `departure` FROM `train_timetable_master` WHERE `date` = ? AND `train_class` = ? AND `train_name` = ? AND `station` = ?',
          reservation[:date].strftime('%Y/%m/%d'),
          reservation[:train_class],
          reservation[:train_name],
          reservation[:departure],
          cast: false,
        ).first

        raise ErrorNoRows, 'departure is not found' if departure.nil?

        arrival = db.xquery(
          'SELECT `arrival` FROM `train_timetable_master` WHERE `date` = ? AND `train_class` = ? AND `train_name` = ? AND `station` = ?',
          reservation[:date].strftime('%Y/%m/%d'),
          reservation[:train_class],
          reservation[:train_name],
          reservation[:arrival],
          cast: false,
        ).first

        raise ErrorNoRows, 'arrival is not found' if arrival.nil?

        reservation_response = {
          reservation_id: reservation[:reservation_id],
          date: reservation[:date].strftime('%Y/%m/%d'),
          amount: reservation[:amount],
          adult: reservation[:adult],
          child: reservation[:child],
          departure: reservation[:departure],
          arrival: reservation[:arrival],
          train_class: reservation[:train_class],
          train_name: reservation[:train_name],
          departure_time: departure[:departure],
          arrival_time: arrival[:arrival],
        }

        reservation_response[:seats] = db.xquery(
          'SELECT * FROM `seat_reservations` WHERE `reservation_id` = ?',
          reservation[:reservation_id],
        ).to_a

        # 1つの予約内で車両番号は全席同じ
        reservation_response[:car_number] = reservation_response[:seats].first[:car_number]

        if reservation_response[:seats].first[:car_number] == 0
          reservation_response[:seat_class] = 'non-reserved'
        else
          seat = db.xquery(
            'SELECT * FROM `seat_master` WHERE `train_class` = ? AND `car_number` = ? AND `seat_column` = ? AND `seat_row` = ?',
            reservation[:train_class],
            reservation_response[:car_number],
            reservation_response[:seats].first[:seat_column],
            reservation_response[:seats].first[:seat_row],
          ).first

          raise ErrorNoRows, 'seat is not found' if seat.nil?

          reservation_response[:seat_class] = seat[:seat_class]
        end

        reservation_response[:seats].each do |v|
          # omit
          v[:reservation_id] = 0
          v[:car_number] = 0
        end

        reservation_response
      end

      def body_params
        @body_params ||= JSON.parse(request.body.tap(&:rewind).read, symbolize_names: true)
      end

      def message_response(message)
        content_type :json

        {
          is_error: false,
          message: message,
        }.to_json
      end

      def halt_with_error(status = 500, message = 'unknown')
        headers = {
          'Content-Type' => 'application/json',
        }
        response = {
          is_error: true,
          message: message,
        }

        halt status, headers, response.to_json
      end
    end

    post '/initialize' do
      db.query('TRUNCATE seat_reservations')
      db.query('TRUNCATE reservations')
      db.query('TRUNCATE users')

      content_type :json
      {
        available_days: AVAILABLE_DAYS,
        language: 'ruby',
      }.to_json
    end

    get '/api/settings' do
      payment_api = ENV['PAYMENT_API'] || 'http://127.0.0.1:5000'

      content_type :json
      { payment_api: payment_api }.to_json
    end

    get '/api/stations' do
      stations = db.query('SELECT * FROM `station_master` ORDER BY `id`').map do |station|
        station.slice(:id, :name, :is_stop_express, :is_stop_semi_express, :is_stop_local)
      end

      content_type :json
      stations.to_json
    end

    require_relative "api/train/search.rb"
    require_relative "api/train/seats.rb"
    require_relative "api/train/reserve.rb"

    post '/api/train/reservation/commit' do
      db.query('BEGIN')

      begin
        # 予約IDで検索
        reservation = begin
          db.xquery(
            'SELECT * FROM `reservations` WHERE `reservation_id` = ?',
            body_params[:reservation_id],
          ).first
        rescue Mysql2::Error => e
          db.query('ROLLBACK')
          puts e.message
          halt_with_error 500, '予約情報の取得に失敗しました'
        end

        if reservation.nil?
          db.query('ROLLBACK')
          halt_with_error 404, '予約情報がみつかりません'
        end

        # 支払い前のユーザチェック。本人以外のユーザの予約を支払ったりキャンセルできてはいけない。
        user, status, message = get_user

        if status != 200
          db.query('ROLLBACK')
          puts message
          halt_with_error status, message
        end

        if reservation[:user_id] != user[:id]
          db.query('ROLLBACK')
          halt_with_error 403, '他のユーザIDの支払いはできません'
        end

        # 予約情報の支払いステータス確認
        if reservation[:status] == 'done'
          db.query('ROLLBACK')
          halt_with_error 403, '既に支払いが完了している予約IDです'
        end

        # 決済する
        pay_info = {
          card_token: body_params[:card_token],
          reservation_id: body_params[:reservation_id],
          amount: reservation[:amount],
        }

        payment_api = ENV['PAYMENT_API'] || 'http://payment:5000'

        uri = URI.parse("#{payment_api}/payment")
        req = Net::HTTP::Post.new(uri)
        req.body = {
          payment_information: pay_info
        }.to_json
        req['Content-Type'] = 'application/json'

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        res = http.start { http.request(req) }

        # リクエスト失敗
        if res.code != '200'
          db.query('ROLLBACK')
          puts res.code
          halt_with_error 500, '決済に失敗しました。カードトークンや支払いIDが間違っている可能性があります'
        end

        # リクエスト取り出し
        output = begin
          JSON.parse(res.body, symbolize_names: true)
        rescue JSON::ParserError => e
          db.query('ROLLBACK')
          puts e.message
          halt_with_error 500, 'JSON parseに失敗しました'
        end

        # 予約情報の更新
        begin
          db.xquery(
            'UPDATE `reservations` SET `status` = ?, `payment_id` = ? WHERE `reservation_id` = ?',
            'done',
            output[:payment_id],
            body_params[:reservation_id],
          )
        rescue Mysql2::Error => e
          db.query('ROLLBACK')
          puts e.message
          halt_with_error 500, '予約情報の更新に失敗しました'
        end
      rescue => e
        puts e.message
        db.query('ROLLBACK')
        halt_with_error 500, e.message
      end

      rr = {
        is_ok: true
      }

      db.query('COMMIT')

      content_type :json
      rr.to_json
    end

    get '/api/auth' do
      user, status, message = get_user

      if status != 200
        puts message
        halt_with_error status, message
      end

      content_type :json
      { email: user[:email] }.to_json
    end

    post '/api/auth/signup' do
      salt = SecureRandom.random_bytes(1024)
      super_secure_password = OpenSSL::PKCS5.pbkdf2_hmac(
        body_params[:password],
        salt,
        100,
        256,
        'sha256',
      )

      db.xquery(
        'INSERT INTO `users` (`email`, `salt`, `super_secure_password`) VALUES (?, ?, ?)',
        body_params[:email],
        salt,
        super_secure_password,
      )

      message_response('registration complete')
    rescue Mysql2::Error => e
      puts e.message
      halt_with_error 502, 'user registration failed'
    end

    post '/api/auth/login' do
      user = db.xquery(
        'SELECT * FROM `users` WHERE `email` = ?',
        body_params[:email],
      ).first

      halt_with_error 403, 'authentication failed' if user.nil?

      challenge_password = OpenSSL::PKCS5.pbkdf2_hmac(
        body_params[:password],
        user[:salt],
        100,
        256,
        'sha256',
      )

      halt_with_error 403, 'authentication failed' if user[:super_secure_password] != challenge_password

      session[:user_id] = user[:id]

      message_response 'autheticated'
    end

    post '/api/auth/logout' do
      session[:user_id] = 0

      message_response 'logged out'
    end

    get '/api/user/reservations' do
      user, status, message = get_user

      if status != 200
        halt_with_error status, message
      end

      reservation_list = db.xquery(
        'SELECT * FROM `reservations` WHERE `user_id` = ?',
        user[:id],
      )

      reservation_response_list = reservation_list.to_a.map do |r|
        make_reservation_response(r)
      end

      content_type :json
      reservation_response_list.to_json
    end

    get '/api/user/reservations/:item_id' do
      user, status, message = get_user

      if status != 200
        halt_with_error status, message
      end

      item_id = params[:item_id].to_i
      if item_id <= 0
        halt_with_error 400, 'incorrect item id'
      end

      reservation = db.xquery(
        'SELECT * FROM `reservations` WHERE `reservation_id` = ? AND `user_id` = ?',
        item_id,
        user[:id],
      ).first

      halt_with_error 404, 'Reservation not found' if reservation.nil?

      reservation_response = make_reservation_response(reservation)

      content_type :json
      reservation_response.to_json
    end

    post '/api/user/reservations/:item_id/cancel' do
      user, code, message = get_user

      if code != 200
        halt_with_error code, message
      end

      item_id = params[:item_id].to_i
      if item_id <= 0
        halt_with_error 400, 'incorrect item id'
      end

      db.query('BEGIN')

      reservation = begin
        db.xquery(
          'SELECT * FROM `reservations` WHERE `reservation_id` = ? AND `user_id` = ?',
          item_id,
          user[:id],
        ).first
      rescue Mysql2::Error => e
        db.query('ROLLBACK')
        puts e.message
        halt_with_error 500, '予約情報の検索に失敗しました'
      end

      if reservation.nil?
        db.query('ROLLBACK')
        halt_with_error 404, 'reservations naiyo'
      end

      case reservation[:status]
      when 'rejected'
        db.query('ROLLBACK')
        halt_with_error 500, '何らかの理由により予約はRejected状態です'
      when 'done'
        # 支払いをキャンセルする
        payment_api = ENV['PAYMENT_API'] || 'http://payment:5000'

        uri = URI.parse("#{payment_api}/payment/#{reservation[:payment_id]}")
        req = Net::HTTP::Delete.new(uri)
        req.body = {
          payment_id: reservation[:payment_id]
        }.to_json
        req['Content-Type'] = 'application/json'

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        res = http.start { http.request(req) }

        # リクエスト失敗
        if res.code != '200'
          db.query('ROLLBACK')
          puts res.code
          halt_with_error 500, '決済に失敗しました。支払いIDが間違っている可能性があります'
        end

        # リクエスト取り出し
        output = begin
          JSON.parse(res.body, symbolize_names: true)
        rescue JSON::ParserError => e
          db.query('ROLLBACK')
          puts e.message
          halt_with_error 500, 'JSON parseに失敗しました'
        end

        puts output
      else
        # pass
      end

      begin
        db.xquery(
          'DELETE FROM `reservations` WHERE `reservation_id` = ? AND `user_id` = ?',
          item_id,
          user[:id],
        )
      rescue Mysql2::Error => e
        db.query('ROLLBACK')
        puts e.message
        halt_with_error 500, e.message
      end

      begin
        db.xquery(
          'DELETE FROM `seat_reservations` WHERE `reservation_id` = ?',
          item_id,
        )
      rescue Mysql2::Error => e
        db.query('ROLLBACK')
        puts e.message
        halt_with_error 500, e.message
      end

      db.query('COMMIT')

      message_response 'cancell complete'
    end

    error do |e|
      content_type :json
      { is_error: true, message: e.message }.to_json
    end
  end
end

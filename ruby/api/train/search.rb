module Isutrain
  class App < Sinatra::Base
    get '/api/train/search' do
      start_time = Time.now
      date = Time.iso8601(params[:use_at]).getlocal
      puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

      halt_with_error 404, '予約可能期間外です' unless check_available_date(date)
      puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

      from_station = db.xquery(
        'SELECT * FROM station_master WHERE name = ?',
        params[:from],
      ).first
      puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

      if from_station.nil?
        puts 'fromStation: no rows'
        halt_with_error 400, 'fromStation: no rows'
      end

      to_station = db.xquery(
        'SELECT * FROM station_master WHERE name = ?',
        params[:to],
      ).first
      puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

      if to_station.nil?
        puts 'toStation: no rows'
        halt_with_error 400, 'toStation: no rows'
      end

      is_nobori = from_station[:distance] > to_station[:distance]

      usable_train_class_list = get_usable_train_class_list(from_station, to_station)
      puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

      train_list = if params[:train_class].nil? || params[:train_class].empty?
        db.xquery(
          'SELECT * FROM `train_master` WHERE `date` = ? AND `train_class` IN (?) AND `is_nobori` = ?',
          date.strftime('%Y/%m/%d'),
          usable_train_class_list,
          is_nobori,
        )
      else
        db.xquery(
          'SELECT * FROM `train_master` WHERE `date` = ? AND `train_class` IN (?) AND `is_nobori` = ? AND `train_class` = ?',
          date.strftime('%Y/%m/%d'),
          usable_train_class_list,
          is_nobori,
          params[:train_class],
        )
      end
      puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

      stations = db.xquery(
        "SELECT * FROM `station_master` ORDER BY `distance` #{is_nobori ? 'DESC' : 'ASC'}",
      )
      puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

      puts "From #{from_station}"
      puts "To #{to_station}"

      train_search_response_list = []

      train_list.each do |train|
        puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"
        is_seeked_to_first_station = false
        is_contains_origin_station = false
        is_contains_dest_station = false
        i = 0

        stations.each do |station|
          unless is_seeked_to_first_station
            # 駅リストを列車の発駅まで読み飛ばして頭出しをする
            # 列車の発駅以前は止まらないので無視して良い
            if station[:name] == train[:start_station]
              is_seeked_to_first_station = true
            else
              next
            end
          end

          if station[:id] == from_station[:id]
            # 発駅を経路中に持つ編成の場合フラグを立てる
            is_contains_origin_station = true
          end

          if station[:id] == to_station[:id]
            if is_contains_origin_station
              # 発駅と着駅を経路中に持つ編成の場合
              is_contains_dest_station = true
            else
              # 出発駅より先に終点が見つかったとき
              puts 'なんかおかしい'
            end

            break
          end

          if station[:name] == train[:last_station]
            # 駅が見つからないまま当該編成の終点に着いてしまったとき
            break
          end

          i += 1
        end

        if is_contains_origin_station && is_contains_dest_station
          # 列車情報

          departure = db.xquery(
            'SELECT `departure` FROM `train_timetable_master` WHERE `date` = ? AND `train_class` = ? AND `train_name` = ? AND `station` = ?',
            date.strftime('%Y/%m/%d'),
            train[:train_class],
            train[:train_name],
            from_station[:name],
            cast: false,
          ).first
          puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

          departure_date = Time.parse("#{date.strftime('%Y/%m/%d')} #{departure[:departure]} +09:00 JST")

          next unless date < departure_date

          arrival = db.xquery(
            'SELECT `arrival` FROM `train_timetable_master` WHERE date = ? AND `train_class` = ? AND `train_name` = ? AND `station` = ?',
            date.strftime('%Y/%m/%d'),
            train[:train_class],
            train[:train_name],
            to_station[:name],
            cast: false,
          ).first
          puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

          premium_avail_seats = get_available_seats(train, from_station, to_station, 'premium', false)
          premium_smoke_avail_seats = get_available_seats(train, from_station, to_station, 'premium', true)
          reserved_avail_seats = get_available_seats(train, from_station, to_station, 'reserved', false)
          reserved_smoke_avail_seats = get_available_seats(train, from_station, to_station, 'reserved', true)

          premium_avail = '○'
          if premium_avail_seats.length.zero?
            premium_avail = '×'
          elsif premium_avail_seats.length < 10
            premium_avail = '△'
          end

          premium_smoke_avail = '○'
          if premium_smoke_avail_seats.length.zero?
            premium_smoke_avail = '×'
          elsif premium_smoke_avail_seats.length < 10
            premium_smoke_avail = '△'
          end

          reserved_avail = '○'
          if reserved_avail_seats.length.zero?
            reserved_avail = '×'
          elsif reserved_avail_seats.length < 10
            reserved_avail = '△'
          end

          reserved_smoke_avail = '○'
          if reserved_smoke_avail_seats.length.zero?
            reserved_smoke_avail = '×'
          elsif reserved_smoke_avail_seats.length < 10
            reserved_smoke_avail = '△'
          end

          # 空席情報
          seat_availability = {
            premium: premium_avail,
            premium_smoke: premium_smoke_avail,
            reserved: reserved_avail,
            reserved_smoke: reserved_smoke_avail,
            non_reserved: '○',
          }
          puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

          # 料金計算
          premium_fare = fare_calc(date, from_station[:id], to_station[:id], train[:train_class], 'premium')
          puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"
          premium_fare = premium_fare * params[:adult].to_i + premium_fare / 2 * params[:child].to_i
          puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

          reserved_fare = fare_calc(date, from_station[:id], to_station[:id], train[:train_class], 'reserved')
          puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"
          reserved_fare = reserved_fare * params[:adult].to_i + reserved_fare / 2 * params[:child].to_i
          puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

          non_reserved_fare = fare_calc(date, from_station[:id], to_station[:id], train[:train_class], 'non-reserved')
          puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"
          non_reserved_fare = non_reserved_fare * params[:adult].to_i + non_reserved_fare / 2 * params[:child].to_i
          puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

          fare_information = {
            premium: premium_fare,
            premium_smoke: premium_fare,
            reserved: reserved_fare,
            reserved_smoke: reserved_fare,
            non_reserved: non_reserved_fare,
          }

          train_search_response = {
            train_class: train[:train_class],
            train_name: train[:train_name],
            start: train[:start_station],
            last: train[:last_station],
            departure: from_station[:name],
            arrival: to_station[:name],
            departure_time: departure[:departure],
            arrival_time: arrival[:arrival],
            seat_availability: seat_availability,
            seat_fare: fare_information,
          }

          train_search_response_list << train_search_response
          puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"

          break if train_search_response_list.length >= 10
        end
      end

      content_type :json
      s = train_search_response_list.to_json
      puts "/api/train/search:#{$$}:#{Thread.current.object_id}:#{__LINE__}: #{Time.now - start_time}"
      s
    end
  end
end

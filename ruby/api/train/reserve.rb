module Isutrain
  class App < Sinatra::Base
    post '/api/train/reserve' do
      date = Time.iso8601(body_params[:date]).getlocal

      halt_with_error 404, '予約可能期間外です' unless check_available_date(date)

      db.query('BEGIN')

      begin
        tmas = begin
          db.xquery(
            'SELECT * FROM `train_master` WHERE `date` = ? AND `train_class` = ? AND `train_name` = ?',
            date.strftime('%Y/%m/%d'),
            body_params[:train_class],
            body_params[:train_name],
          ).first
        rescue Mysql2::Error => e
          db.query('ROLLBACK')
          puts e.message
          halt_with_error 500, '列車データの取得に失敗しました'
        end

        if tmas.nil?
          db.query('ROLLBACK')
          halt_with_error 404, '列車データがみつかりません'
        end

        puts tmas

        # 列車自体の駅IDを求める
        departure_station = begin
          db.xquery(
            'SELECT * FROM `station_master` WHERE `name` = ?',
            tmas[:start_station],
          ).first
        rescue Mysql2::Error => e
          db.query('ROLLBACK')
          puts e.message
          halt_with_error 500, 'リクエストされた列車の始発駅データの取得に失敗しました'
        end

        if departure_station.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'リクエストされた列車の始発駅データがみつかりません'
        end

        # Arrive
        arrival_station = begin
          db.xquery(
            'SELECT * FROM `station_master` WHERE `name` = ?',
            tmas[:last_station],
          ).first
        rescue Mysql2::Error => e
          db.query('ROLLBACK')
          puts e.message
          halt_with_error 500, 'リクエストされた列車の終着駅データの取得に失敗しました'
        end

        if arrival_station.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'リクエストされた列車の終着駅データがみつかりません'
        end

        # From
        from_station = begin
          db.xquery(
            'SELECT * FROM `station_master` WHERE `name` = ?',
            body_params[:departure],
          ).first
        rescue Mysql2::Error => e
          db.query('ROLLBACK')
          puts e.message
          halt_with_error 500, '乗車駅データの取得に失敗しました'
        end

        if from_station.nil?
          db.query('ROLLBACK')
          halt_with_error 404, "乗車駅データがみつかりません #{body_params[:departure]}"
        end

        # To
        to_station = begin
          db.xquery(
            'SELECT * FROM `station_master` WHERE `name` = ?',
            body_params[:arrival],
          ).first
        rescue Mysql2::Error => e
          db.query('ROLLBACK')
          puts e.message
          halt_with_error 500, '降車駅駅データの取得に失敗しました'
        end

        if to_station.nil?
          db.query('ROLLBACK')
          halt_with_error 404, "降車駅駅データがみつかりません #{body_params[:arrival]}"
        end

        case body_params[:train_class]
        when '最速'
          if !from_station[:is_stop_express] || !to_station[:is_stop_express]
            db.query('ROLLBACK')
            halt_with_error 400, '最速の止まらない駅です'
          end
        when '中間'
          if !from_station[:is_stop_semi_express] || !to_station[:is_stop_semi_express]
            db.query('ROLLBACK')
            halt_with_error 400, '中間の止まらない駅です'
          end
        when '遅いやつ'
          if !from_station[:is_stop_local] || !to_station[:is_stop_local]
            db.query('ROLLBACK')
            halt_with_error 400, '遅いやつの止まらない駅です'
          end
        else
          db.query('ROLLBACK')
          halt_with_error 400, 'リクエストされた列車クラスが不明です'
        end

        # 運行していない区間を予約していないかチェックする
        if tmas[:is_nobori]
          if from_station[:id] > departure_station[:id] || to_station[:id] > departure_station[:id]
            db.query('ROLLBACK')
            halt_with_error 400, 'リクエストされた区間に列車が運行していない区間が含まれています'
          end

          if arrival_station[:id] >= from_station[:id] || arrival_station[:id] > to_station[:id]
            db.query('ROLLBACK')
            halt_with_error 400, 'リクエストされた区間に列車が運行していない区間が含まれています'
          end
        else
          if from_station[:id] < departure_station[:id] || to_station[:id] < departure_station[:id]
            db.query('ROLLBACK')
            halt_with_error 400, 'リクエストされた区間に列車が運行していない区間が含まれています'
          end

          if arrival_station[:id] <= from_station[:id] || arrival_station[:id] < to_station[:id]
            db.query('ROLLBACK')
            halt_with_error 400, 'リクエストされた区間に列車が運行していない区間が含まれています'
          end
        end

        # あいまい座席検索
        # seatsが空白の時に発動する
        if body_params[:seats].empty?
          if body_params[:seat_class] != 'non-reserved'
            train = begin
              db.xquery(
                'SELECT * FROM `train_master` WHERE `date` = ? AND `train_class` = ? AND `train_name` = ?',
                date.strftime('%Y/%m/%d'),
                body_params[:train_class],
                body_params[:train_name],
              ).first
            rescue Mysql2::Error => e
              db.query('ROLLBACK')
              puts e.message
              halt_with_error 400, e.message
            end

            if train.nil?
              db.query('ROLLBACK')
              halt_with_error 404, 'train is not found'
            end

            usable_train_class_list = get_usable_train_class_list(from_station, to_station)
            unless usable_train_class_list.include?(train[:train_class])
              err = 'invalid train_class'
              puts err
              db.query('ROLLBACK')
              halt_with_error 400, err
            end

            body_params[:seats] = [] # 座席リクエスト情報は空に
            (1..16).each do |carnum|
              seat_list = begin
                db.xquery(
                  'SELECT * FROM `seat_master` WHERE `train_class` = ? AND `car_number` = ? AND `seat_class` = ? AND `is_smoking_seat` = ? ORDER BY `seat_row`, `seat_column`',
                  body_params[:train_class],
                  carnum,
                  body_params[:seat_class],
                  !!body_params[:is_smoking_seat],
                )
              rescue Mysql2::Error => e
                db.query('ROLLBACK')
                puts e.message
                halt_with_error 400, e.message
              end

              seat_information_list = []
              seat_list.each do |seat|
                s = {
                  row: seat[:seat_row],
                  column: seat[:seat_column],
                  class: seat[:seat_class],
                  is_smoking_seat: seat[:is_smoking_seat],
                  is_occupied: false,
                }

                seat_reservation_list = begin
                  db.xquery(
                    'SELECT `s`.* FROM `seat_reservations` `s`, `reservations` `r` WHERE `r`.`date` = ? AND `r`.`train_class` = ? AND `r`.`train_name` = ? AND `car_number` = ? AND `seat_row` = ? AND `seat_column` = ? FOR UPDATE',
                    date.strftime('%Y/%m/%d'),
                    seat[:train_class],
                    body_params[:train_name],
                    seat[:car_number],
                    seat[:seat_row],
                    seat[:seat_column],
                  )
                rescue Mysql2::Error => e
                  db.query('ROLLBACK')
                  puts e.message
                  halt_with_error 400, e.message
                end

                seat_reservation_list.each do |seat_reservation|
                  reservation = begin
                    db.xquery(
                      'SELECT * FROM `reservations` WHERE `reservation_id` = ? FOR UPDATE',
                      seat_reservation[:reservation_id],
                    ).first
                  rescue Mysql2::Error => e
                    db.query('ROLLBACK')
                    puts e.message
                    halt_with_error 400, e.message
                  end

                  if reservation.nil?
                    db.query('ROLLBACK')
                    halt_with_error 404, 'reservation is not found'
                  end

                  departure_station = begin
                    db.xquery(
                      'SELECT * FROM `station_master` WHERE `name` = ?',
                      reservation[:departure],
                    ).first
                  rescue Mysql2::Error => e
                    db.query('ROLLBACK')
                    puts e.message
                    halt_with_error 400, e.message
                  end

                  if departure_station.nil?
                    db.query('ROLLBACK')
                    halt_with_error 404, 'departure_station is not found'
                  end

                  arrival_station = begin
                    db.xquery(
                      'SELECT * FROM `station_master` WHERE `name` = ?',
                      reservation[:arrival],
                    ).first
                  rescue Mysql2::Error => e
                    db.query('ROLLBACK')
                    puts e.message
                    halt_with_error 400, e.message
                  end

                  if arrival_station.nil?
                    db.query('ROLLBACK')
                    halt_with_error 404, 'arrival_station is not found'
                  end

                  if train[:is_nobori]
                    # 上り
                    if to_station[:id] < arrival_station[:id] && from_station[:id] <= arrival_station[:id]
                      # pass
                    elsif to_station[:id] >= departure_station[:id] && from_station[:id] > departure_station[:id]
                      # pass
                    else
                      s[:is_occupied] = true
                    end
                  else
                    # 下り
                    if from_station[:id] < departure_station[:id] && to_station[:id] <= departure_station[:id]
                      # pass
                    elsif from_station[:id] >= arrival_station[:id] && to_station[:id] > arrival_station[:id]
                      # pass
                    else
                      s[:is_occupied] = true
                    end
                  end
                end

                seat_information_list << s
              end

              # 曖昧予約席とその他の候補席を選出
              vague_seat = {}


              reserved = false
              vargue = true
              seatnum = body_params[:adult] + body_params[:child] - 1     # 全体の人数からあいまい指定席分を引いておく
              if body_params[:column].nil? || body_params[:column].empty? # A/B/C/D/Eを指定しなければ、空いている適当な指定席を取るあいまいモード
                seatnum = body_params[:adult] + body_params[:child]       # あいまい指定せず大人＋小人分の座席を取る
                reserved = true                                           # dummy
                vargue = false                                            # dummy
              end

              candidate_seats = []

              # シート分だけ回して予約できる席を検索
              i = 0
              seat_information_list.each do |seat|
                if seat[:column] == body_params[:column] && !seat[:is_occupied] && !reserved && vargue # あいまい席があいてる
                  vague_seat = seat
                  reserved = true
                elsif !seat[:is_occupied] && i < seatnum # 単に席があいてる
                  candidate_seats << {
                    row: seat[:row],
                    column: seat[:column],
                  }

                  i += 1
                end
              end

              if vargue && reserved
                body_params[:seats] << vague_seat
              end

              if i > 0
                body_params[:seats].concat(candidate_seats)
              end

              if body_params[:seats].length < body_params[:adult] + body_params[:child]
                # リクエストに対して席数が足りてない
                # 次の号車にうつしたい
                puts '-----------------'
                puts "現在検索中の車両: #{carnum}号車, リクエスト座席数: #{body_params[:adult] + body_params[:child]}, 予約できそうな座席数: #{body_params[:seats].length}, 不足数: #{body_params[:adult] + body_params[:child] - body_params[:seats].length}"
                puts 'リクエストに対して座席数が不足しているため、次の車両を検索します。'

                body_params[:seats] = []
                if carnum == 16
                  puts 'この新幹線にまとめて予約できる席数がなかったから検索をやめるよ'
                  break
                end
              end

              puts "空き実績: #{carnum}号車 シート: #{body_params[:seats]} 席数: #{body_params[:seats].length}"

              if body_params[:seats].length >= body_params[:adult] + body_params[:child]
                puts '予約情報に追加したよ'

                body_params[:seats] = body_params[:seats][0, body_params[:adult] + body_params[:child]]
                body_params[:car_number] = carnum

                break
              end
            end

            if body_params[:seats].length.zero?
              db.query('ROLLBACK')
              halt_with_error 404, 'あいまい座席予約ができませんでした。指定した席、もしくは1車両内に希望の席数をご用意できませんでした。'
            end
          end
        else
          # 座席情報のValidate
          body_params[:seats].each do |z|
            puts "XXXX #{z}"

            seat_list = begin
              db.xquery(
                'SELECT * FROM `seat_master` WHERE `train_class` = ? AND `car_number` = ? AND `seat_column` = ? AND `seat_row` = ? AND `seat_class` = ?',
                body_params[:train_class],
                body_params[:car_number],
                z[:column],
                z[:row],
                body_params[:seat_class],
              )
            rescue Mysql2::Error => e
              puts e.message
              db.query('ROLLBACK')
              halt_with_error 400, e.message
            end

            if seat_list.to_a.empty?
              db.query('ROLLBACK')
              halt_with_error 404, 'リクエストされた座席情報は存在しません。号車・喫煙席・座席クラスなど組み合わせを見直してください'
            end
          end
        end

        reservations = begin
          db.xquery(
            'SELECT * FROM `reservations` WHERE `date` = ? AND `train_class` = ? AND `train_name` = ? FOR UPDATE',
            date.strftime('%Y/%m/%d'),
            body_params[:train_class],
            body_params[:train_name],
          )
        rescue Mysql2::Error => e
          puts e.message
          db.query('ROLLBACK')
          halt_with_error 500, '列車予約情報の取得に失敗しました'
        end

        reservations.each do |reservation|
          break if body_params[:seat_class] == 'non-reserved'

          # train_masterから列車情報を取得(上り・下りが分かる)
          tmas = begin
            db.xquery(
              'SELECT * FROM `train_master` WHERE `date` = ? AND `train_class` = ? AND `train_name` = ?',
              date.strftime('%Y/%m/%d'),
              body_params[:train_class],
              body_params[:train_name],
            ).first
          rescue Mysql2::Error => e
            puts e.message
            db.query('ROLLBACK')
            halt_with_error 500, '列車データの取得に失敗しました'
          end

          if tmas.nil?
            db.query('ROLLBACK')
            halt_with_error 404, '列車データがみつかりません'
          end

          # 予約情報の乗車区間の駅IDを求める

          # From
          reserved_from_station = begin
            db.xquery(
              'SELECT * FROM `station_master` WHERE `name` = ?',
              reservation[:departure],
            ).first
          rescue Mysql2::Error => e
            puts e.message
            db.query('ROLLBACK')
            halt_with_error 500, '予約情報に記載された列車の乗車駅データの取得に失敗しました'
          end

          if reserved_from_station.nil?
            db.query('ROLLBACK')
            halt_with_error 404, '予約情報に記載された列車の乗車駅データがみつかりません'
          end

          # To
          reserved_to_station = begin
            db.xquery(
              'SELECT * FROM `station_master` WHERE `name` = ?',
              reservation[:arrival],
            ).first
          rescue Mysql2::Error => e
            puts e.message
            db.query('ROLLBACK')
            halt_with_error 500, '予約情報に記載された列車の降車駅データの取得に失敗しました'
          end

          if reserved_to_station.nil?
            db.query('ROLLBACK')
            halt_with_error 404, '予約情報に記載された列車の降車駅データがみつかりません'
          end

          # 予約の区間重複判定
          secdup = false
          if tmas[:is_nobori]
            # 上り
            if to_station[:id] < reserved_to_station[:id] && from_station[:id] <= reserved_to_station[:id]
              # pass
            elsif to_station[:id] >= reserved_from_station[:id] && from_station > reserved_from_station[:id]
              # pass
            else
              secdup = true
            end
          else
            # 下り
            if from_station[:id] < reserved_from_station[:id] && to_station[:id] <= reserved_from_station[:id]
              # pass
            elsif from_station[:id] >= reserved_to_station[:id] && to_station[:id] > reserved_to_station[:id]
              # pass
            else
              secdup = true
            end
          end

          if secdup
            # 区間重複の場合は更に座席の重複をチェックする
            seat_reservations = begin
              db.xquery(
                'SELECT * FROM `seat_reservations` WHERE `reservation_id` = ? FOR UPDATE',
                reservation[:reservation_id],
              )
            rescue Mysql2::Error => e
              puts e.message
              db.query('ROLLBACK')
              halt_with_error 500, '座席予約情報の取得に失敗しました'
            end

            seat_reservations.each do |v|
              body_params[:seats].each do |seat|
                if v[:car_number] == body_params[:car_number] && v[:seat_row] == seat[:row] && v[:seat_column] == seat[:column]
                  db.query('ROLLBACK')
                  puts "Duplicated #{reservation}"
                  halt_with_error 400, 'リクエストに既に予約された席が含まれています'
                end
              end
            end
          end
        end

        # 3段階の予約前チェック終わり

        # 自由席は強制的にSeats情報をダミーにする（自由席なのに席指定予約は不可）
        if body_params[:seat_class] == 'non-reserved'
          body_params[:seats] = []
          body_params[:car_number] = 0

          (body_params[:adult] + body_params[:child]).times do
            body_params[:seats] << {
              row: 0,
              column: '',
            }
          end
        end

        # 運賃計算
        fare = begin
          case body_params[:seat_class]
          when 'premium', 'reserved', 'non-reserved'
            fare_calc(date, from_station[:id], to_station[:id], body_params[:train_class], body_params[:seat_class])
          else
            raise Error, 'リクエストされた座席クラスが不明です'
          end
        rescue Error, ErrorNoRows => e
          db.query('ROLLBACK')
          puts "fareCalc #{e.message}"
          halt_with_error 400, e.message
        end

        sum_fare = (body_params[:adult] * fare) + (body_params[:child] * fare) / 2
        puts 'SUMFARE'

        # userID取得。ログインしてないと怒られる。
        user, status, message = get_user

        if status != 200
          db.query('ROLLBACK')
          puts message
          halt_with_error status, message
        end

        # 予約ID発行と予約情報登録
        begin
          db.xquery(
            'INSERT INTO `reservations` (`user_id`, `date`, `train_class`, `train_name`, `departure`, `arrival`, `status`, `payment_id`, `adult`, `child`, `amount`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            user[:id],
            date.strftime('%Y/%m/%d'),
            body_params[:train_class],
            body_params[:train_name],
            body_params[:departure],
            body_params[:arrival],
            'requesting',
            'a',
            body_params[:adult],
            body_params[:child],
            sum_fare,
          )
        rescue Mysql2::Error => e
          db.query('ROLLBACK')
          puts e.message
          halt_with_error 400, "予約の保存に失敗しました。 #{e.message}"
        end

        id = db.last_id # 予約ID
        if id.nil?
          db.query('ROLLBACK')
          halt_with_error 500, '予約IDの取得に失敗しました'
        end

        # 席の予約情報登録
        # reservationsレコード1に対してseat_reservationstが1以上登録される
        body_params[:seats].each do |v|
          db.xquery(
            'INSERT INTO `seat_reservations` (`reservation_id`, `car_number`, `seat_row`, `seat_column`) VALUES (?, ?, ?, ?)',
            id,
            body_params[:car_number],
            v[:row],
            v[:column],
          )
        rescue Mysql2::Error => e
          db.query('ROLLBACK')
          puts e.message
          halt_with_error 500, '座席予約の登録に失敗しました'
        end
      rescue => e
        puts e.message
        db.query('ROLLBACK')
        halt_with_error 500, e.message
      end

      response = {
        reservation_id: id,
        amount: sum_fare,
        is_ok: true
      }

      db.query('COMMIT')

      content_type :json
      response.to_json
    end
  end
end

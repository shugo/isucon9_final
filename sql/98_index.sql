/*
CREATE INDEX index_search_train_timetable_master ON train_timetable_master(date, train_class, train_name, station);

CREATE INDEX index_station_master_name ON station_master(name);
CREATE INDEX index_station_master_is_stop_express ON station_master(is_stop_express);
CREATE INDEX index_station_master_is_stop_semi_express ON station_master(is_stop_semi_express);
CREATE INDEX index_station_master_is_stop_local ON station_master(is_stop_local);

CREATE INDEX index_seat_master_train_class ON seat_master(train_class);
CREATE INDEX index_seat_master_car_number ON seat_master(car_number);
CREATE INDEX index_seat_master_seat_column ON seat_master(seat_column);
CREATE INDEX index_seat_master_seat_row ON seat_master(seat_row);
CREATE INDEX index_seat_master_seat_class ON seat_master(seat_class);
CREATE INDEX index_seat_master_is_smoking_seat ON seat_master(is_smoking_seat);

CREATE INDEX index_train_master_date ON train_master(date);
CREATE INDEX index_train_master_departure_at ON train_master(departure_at);
CREATE INDEX index_train_master_train_class ON train_master(train_class);
CREATE INDEX index_train_master_train_name ON train_master(train_name);
CREATE INDEX index_train_master_start_station ON train_master(start_station);
CREATE INDEX index_train_master_last_station ON train_master(last_station);
CREATE INDEX index_train_master_is_nobori ON train_master(is_nobori);

CREATE INDEX index_reservations_user_id ON reservations(user_id);

CREATE INDEX index_seat_reservations_reservation_id ON seat_reservations(reservation_id);
CREATE INDEX index_seat_reservations_car_number ON seat_reservations(car_number);
*/

CREATE INDEX index_seat_reservations_seat_column ON seat_reservations(seat_column);
CREATE INDEX index_seat_reservations_seat_row ON seat_reservations(seat_row);

CREATE INDEX index_reservations_train_class ON reservations(train_class);
CREATE INDEX index_reservations_departure ON reservations(departure);
CREATE INDEX index_reservations_arrival ON reservations(arrival);

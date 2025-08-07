drop database myps2;
create database if not exists myps2;

use myps2;

create table if not exists games (
pk_game_name varchar(50) primary key,
developer varchar(30) not null,
publisher varchar(30) not null,
launch_date date not null,
director char(20) not null
);

insert into games values
('Resident Evil 4', 'CAPCOM', 'CAPCOM', '2005-04-11', 'Shinji Mikami'),
('Okami', 'CLOVER STUDIO', 'Activision', '2006-04-20', 'Hideki Kamiya'),
('DarkWatch', 'High Moon Studio','CAPCOM', '2005-08-16', 'Chris Ulm');


create table generalization(
id_generalization int primary key, 
genre varchar(50)
);

create table games_genres(
pk_game_name varchar(50),
id_generalization int,
primary key (pk_game_name, id_generalization),
foreign key (pk_game_name) references games (pk_game_name),
foreign key (id_generalization) references generalization(id_generalization)
);

insert into generalization values
(1, 'Survival Horror'),
(2, 'Puzzle'),
(3, 'Adventure'),
(4, 'Shooter'),
(5, 'FPS'),
(6, 'Arcade'),
(7, 'Racing'),
(8, 'Hack and Slash'),
(9, 'Brawler'),
(10,'2D Fighter'),
(11, '3D Fighter'),
(12, 'Horror'),
(13, 'Platformer');



















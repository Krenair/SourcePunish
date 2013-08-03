CREATE TABLE IF NOT EXISTS `sourcepunish_punishments` (
	`Punish_ID` INT(11) NOT NULL AUTO_INCREMENT,
	`Punish_Time` INT(15) NOT NULL,
	`Punish_Server_ID` INT(11) NOT NULL,
	`Punish_Player_Name` VARCHAR(60) NOT NULL,
	`Punish_Player_ID` VARCHAR(60) NOT NULL,
	`Punish_Player_IP` VARCHAR(22) NOT NULL,
	`Punish_Auth_Type` varchar(16) NOT NULL DEFAULT 'steam',
	`Punish_Type` VARCHAR(16) NOT NULL,
	`Punish_Length` INT(8) NOT NULL,
	`Punish_Reason` VARCHAR(70) NOT NULL,
	`Punish_All_Servers` tinyint(1) NOT NULL DEFAULT '1',
	`Punish_All_Mods` tinyint(1) NOT NULL DEFAULT '0',
	`Punish_Admin_Name` VARCHAR(30) NOT NULL,
	`Punish_Admin_ID` VARCHAR(60) NOT NULL,
	`UnPunish` tinyint(1) NOT NULL DEFAULT '0',
	`UnPunish_Admin_Name` VARCHAR(60) NOT NULL,
	`UnPunish_Admin_ID` VARCHAR(60) NOT NULL,
	`UnPunish_Time` INT(15) NOT NULL,
	`UnPunish_Reason` VARCHAR(70) NOT NULL,
	PRIMARY KEY (`Punish_ID`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1;

CREATE TABLE IF NOT EXISTS `sourcepunish_servers` (
	`ID` INT(11) NOT NULL AUTO_INCREMENT,
	`Server_IP` VARCHAR(22) NOT NULL,
	`Server_Host` VARCHAR(40) NOT NULL,
	`Server_Name` VARCHAR(30) NOT NULL,
	`Server_Mod` INT(5) NOT NULL,
	PRIMARY KEY (`ID`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1;

CREATE TABLE IF NOT EXISTS `sourcepunish_server_mods` (
	`Mod_ID` INT(11) NOT NULL AUTO_INCREMENT,
	`Mod_Short` VARCHAR(10) NOT NULL,
	`Mod_Name` VARCHAR(35) NOT NULL,
	PRIMARY KEY (`Mod_ID`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1;

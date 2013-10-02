import getpass, MySQLdb, re
conn = MySQLdb.connect(host = raw_input("Hostname: "), port = int(raw_input("Port number: ")), user = raw_input("Username: "), passwd = getpass.getpass(), db = raw_input("DB name: "))
db = conn.cursor()
db.execute("SELECT * FROM zerotolerance")
rowsToInsert = []
steamIdRegex = re.compile("^STEAM_[0-7]:[01]:\\d+$")

for row in db.fetchall():
	id, type, punished_id, punished_name, punisher_id, punisher_name, remover_id, remover_name, start_time, end_time, removal_time, reason, removal_reason = row

	if type == 'Unknown':
		continue

	if end_time == 0 or end_time == start_time:
		length = 0
	else:
		length = (end_time - start_time) / 60

	if remover_name == '':
		removed = 0
	else:
		removed = 1

	if punisher_id == 'Server':
		punisher_id = 'Console'

	if len(punisher_name) > 32:
		punisher_name = punisher_name[:32] # The entries with server names (when the console set the punishment) are too big

	if len(punished_name) > 32:
		punished_name = punished_name[:32]

	if len(remover_name) > 32:
		remover_name = remover_name[:32]

	if length < 0:
		#ZT id 685 by Saber against 'The Master Medic' somehow managed to get a massive negative number as the expiry time
		length = 0

	rowsToInsert.append((type.lower(), punished_name, punished_id, "", punisher_name, punisher_id, removed, remover_id, remover_name, start_time, length, removal_time, reason, removal_reason, -1))

insertQuery = "INSERT INTO sourcepunish_punishments (Punish_Type, Punish_Player_Name, Punish_Player_ID, Punish_Player_IP, Punish_Admin_Name, Punish_Admin_ID, UnPunish, UnPunish_Admin_ID, UnPunish_Admin_Name, Punish_Time, Punish_Length, UnPunish_Time, Punish_Reason, UnPunish_Reason, Punish_Server_ID) VALUES "
for row in rowsToInsert:
	insertQuery += '('
	for i in range(0, len(row)):
		element = row[i]

		if isinstance(element, str):
			insertQuery += '\'' + conn.escape_string(element) + '\''
		elif isinstance(element, int) or isinstance(element, long):
			insertQuery += str(element)

		if i + 1 != len(row):
			insertQuery += ', '
	insertQuery += '),\n'

insertQuery = insertQuery[:-2] + ';'
#print insertQuery

if raw_input("Are you sure? [y/N] ") == 'y':
	db.execute(insertQuery)
	print 'Done!'
else:
	print 'Okay, exiting.'

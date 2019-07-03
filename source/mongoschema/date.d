/// This module provides Date serialization with an extra added magic value to serialize the current date at serialization time.
module mongoschema.date;

import std.datetime.systime;
import std.traits : isSomeString;

import vibe.data.bson;

/// Class serializing to a bson date containing a special `now` value that gets translated to the current time when converting to bson.
final struct SchemaDate
{
public @safe:
	///
	this(BsonDate date)
	{
		_time = date.value;
	}

	///
	this(long time)
	{
		_time = time;
	}

	///
	@property auto time() const
	{
		return _time;
	}

	///
	static Bson toBson(SchemaDate date)
	{
		if (date._time == -1)
		{
			return Bson(BsonDate.fromStdTime(Clock.currStdTime()));
		}
		else
		{
			return Bson(BsonDate(date._time));
		}
	}

	///
	static SchemaDate fromBson(Bson bson)
	{
		return SchemaDate(bson.get!BsonDate.value);
	}

	///
	static SchemaDate fromSysTime(SysTime stime)
	{
		return SchemaDate(BsonDate(stime).value);
	}

	/// Magic value setting the date to the current time stamp when serializing.
	static SchemaDate now()
	{
		return SchemaDate(-1);
	}

	/// Converts this SchemaDate to a std.datetime.SysTime object.
	SysTime toSysTime() const
	{
		if (_time == -1)
			return Clock.currTime;
		return BsonDate(_time).toSysTime();
	}

	/// Converts this SchemaDate to a vibed BsonDate object.
	BsonDate toBsonDate() const
	{
		return BsonDate(_time);
	}

	///
	string toISOExtString() const
	{
		return toSysTime.toISOExtString;
	}

	///
	static SchemaDate fromISOExtString(S)(in S s) if (isSomeString!S)
	{
		return SchemaDate.fromSysTime(SysTime.fromISOExtString(s));
	}

private:
	long _time;
}

static assert (isISOExtStringSerializable!SchemaDate);

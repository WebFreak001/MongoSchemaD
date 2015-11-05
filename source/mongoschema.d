module mongoschema;

import vibe.data.bson;
import vibe.db.mongo.collection;
import vibe.db.mongo.connection;
import std.datetime;
import std.traits;

// Attributes
enum schemaIgnore;
struct encode { string func; }
struct decode { string func; }
struct binaryType { BsonBinData.Type type = BsonBinData.Type.generic; }
struct schemaName { string name; }

template isVariable(alias T)
{
    enum isVariable = !is(T) && is(typeof(T)) && !isCallable!T;
}
template isVariable(T)
{
    enum isVariable = false; // Types are no variables
}

template getUDAs(alias symbol, alias attribute)
{
    import std.typetuple : Filter;

    enum isDesiredUDA(alias S) = is(typeof(S) == attribute);
    alias getUDAs = Filter!(isDesiredUDA, __traits(getAttributes, symbol));
}

private Bson memberToBson(T)(T member)
{
	static if(__traits(hasMember, T, "toBson") && is(ReturnType!(typeof(T.toBson)) == Bson))
	{
		// Custom defined toBson
		return T.toBson(member);
	}
	else static if(!isBasicType!T && !isArray!T && !is(T == enum) && !is(T == Bson) && !isAssociativeArray!T)
	{
		// Mixed in MongoSchema
		return member._toSchemaBson();
	}
	else // Generic value
	{
		static if(is(T == enum))
		{ // Enum value
			return Bson(cast(OriginalType!T) member);
		}
		else static if(isArray!(T) && !isSomeString!T)
		{ // Arrays of anything except strings
			Bson[] values;
			foreach(val; member)
				values ~= memberToBson(val);
			return Bson(values);
		}
		else static if(isAssociativeArray!T)
		{ // Associative Arrays (Objects)
			Bson[string] values;
			foreach(name, val; member)
				values[name] = memberToBson(val);
			return Bson(values);
		}
		else static if(is(T == Bson))
		{ // Already a Bson object
			return member;
		}
		else
		{ // Check if this can be passed
			static assert(__traits(compiles, { Bson(member); }), "Type '" ~ T.stringof ~ "' is incompatible with Bson schemas");
			return Bson(member);
		}
	}
}

private T bsonToMember(T)(T member, Bson value)
{
	static if(__traits(hasMember, T, "fromBson") && is(ReturnType!(typeof(T.fromBson)) == T))
	{
		// Custom defined toBson
		return T.fromBson(value);
	}
	else static if(!isBasicType!T && !isArray!T && !is(T == enum) && !is(T == Bson) && !isAssociativeArray!T)
	{
		// Mixed in MongoSchema
		return value._toSchemaValue!T();
	}
	else // Generic value
	{
		static if(is(T == enum))
		{ // Enum value
			return cast(T) value.get!(OriginalType!T);
		}
		else static if(isArray!(T) && !isSomeString!T)
		{ // Arrays of anything except strings
			T values;
			foreach(val; value)
				values ~= bsonToMember(member, val);
			return values;
		}
		else static if(isAssociativeArray!T)
		{ // Associative Arrays (Objects)
			T values;
			foreach(name, val; value)
				values[name] = bsonToMember(member, val);
			return values;
		}
		else static if(is(T == Bson))
		{ // Already a Bson object
			return member;
		}
		else
		{ // Check if this can be passed
			static assert(__traits(compiles, { value.get!T(); }), "Type '" ~ T.stringof ~ "' incompatible with Bson schemas");
			return value.get!T();
		}
	}
}

/// Generated function for generating
Bson _toSchemaBson(T)(T obj)
{
	Bson data = Bson.emptyObject;

	foreach(memberName; __traits(allMembers, T))
	{
		static if(__traits(compiles, { static s = isVariable!(__traits(getMember, obj, memberName)); }) && isVariable!(__traits(getMember, obj, memberName)))
		{
			static if(__traits(getProtection, __traits(getMember, obj, memberName)) == "public")
			{
				string name = memberName;
				Bson value;
				static if(hasUDA!((__traits(getMember, obj, memberName)), schemaIgnore))
					continue;
				static if(hasUDA!((__traits(getMember, obj, memberName)), schemaName))
				{
					static assert(getUDAs!((__traits(getMember, obj, memberName)), schemaName).length == 1, "Member '" ~ memberName ~ "' can only have one name!");
					name = getUDAs!((__traits(getMember, obj, memberName)), schemaName)[0].name;
				}

				static if(hasUDA!((__traits(getMember, obj, memberName)), encode))
				{
					static assert(getUDAs!((__traits(getMember, obj, memberName)), encode).length == 1, "Member '" ~ memberName ~ "' can only have one encoder!");
					mixin("value = obj." ~ getUDAs!((__traits(getMember, obj, memberName)), encode)[0].func ~ "(obj);");
				}
				else static if(hasUDA!((__traits(getMember, obj, memberName)), binaryType))
				{
					static assert(isArray!(typeof((__traits(getMember, obj, memberName)))) && typeof((__traits(getMember, obj, memberName))[0]).sizeof == 1, "Binary member '" ~ memberName ~ "' can only be an array of 1 byte values");
					static assert(getUDAs!((__traits(getMember, obj, memberName)), binaryType).length == 1, "Binary member '" ~ memberName ~ "' can only have one type!");
					BsonBinData.Type type = getUDAs!((__traits(getMember, obj, memberName)), binaryType)[0].type;
					value = Bson(BsonBinData(type, cast(immutable(ubyte)[]) (__traits(getMember, obj, memberName))));
				}
				else
				{
					static if(__traits(hasMember, typeof((__traits(getMember, obj, memberName))), "toBson") && !is(ReturnType!(typeof((__traits(getMember, obj, memberName)).toBson)) == Bson))
						pragma(msg, "Warning: ", typeof((__traits(getMember, obj, memberName))).stringof, ".toBson does not return a vibe.data.bson.Bson struct!");

					value = memberToBson(__traits(getMember, obj, memberName));
				}
				data[name] = value;
			}
		}
	}

	return data;
}

T _toSchemaValue(T)(Bson bson)
{
	T obj = T.init;

	foreach(memberName; __traits(allMembers, T))
	{
		static if(__traits(compiles, { static s = isVariable!(__traits(getMember, obj, memberName)); }) && isVariable!(__traits(getMember, obj, memberName)))
		{
			static if(__traits(getProtection, __traits(getMember, obj, memberName)) == "public")
			{
				string name = memberName;
				static if(hasUDA!((__traits(getMember, obj, memberName)), schemaIgnore))
					continue;
				static if(hasUDA!((__traits(getMember, obj, memberName)), schemaName))
				{
					static assert(getUDAs!((__traits(getMember, obj, memberName)), schemaName).length == 1, "Member '" ~ memberName ~ "' can only have one name!");
					name = getUDAs!((__traits(getMember, obj, memberName)), schemaName)[0].name;
				}

				// compile time code will still be generated but not run at runtime
				if(bson.tryIndex(name).isNull)
					continue;

				static if(hasUDA!((__traits(getMember, obj, memberName)), decode))
				{
					static assert(getUDAs!((__traits(getMember, obj, memberName)), decode).length == 1, "Member '" ~ memberName ~ "' can only have one decoder!");
					mixin("obj." ~ memberName ~ " = obj." ~ getUDAs!((__traits(getMember, obj, memberName)), decode)[0].func ~ "(bson);");
				}
				else static if(hasUDA!((__traits(getMember, obj, memberName)), binaryType))
				{
					static assert(isArray!(typeof((__traits(getMember, obj, memberName)))) && typeof((__traits(getMember, obj, memberName))[0]).sizeof == 1, "Binary member '" ~ memberName ~ "' can only be an array of 1 byte values");
					static assert(getUDAs!((__traits(getMember, obj, memberName)), binaryType).length == 1, "Binary member '" ~ memberName ~ "' can only have one type!");
					assert(bson[name].type == Bson.Type.binData);
					auto data = bson[name].get!(BsonBinData).rawData;
					mixin("obj." ~ memberName ~ " = cast(typeof(obj." ~ memberName ~ ")) data;");
				}
				else
				{
					mixin("obj." ~ memberName ~ " = bsonToMember(__traits(getMember, obj, memberName), bson[name]);");
				}
			}
		}
	}

	return obj;
}

auto findSchema(T, U)(MongoCollection collection, T value, U returnFieldSelector, QueryFlags flags = QueryFlags.None, int num_skip = 0, int num_docs_per_chunk = 0)
{
	return collection.find(value._toSchemaBson(), returnFieldSelector, flags, num_skip, num_docs_per_chunk);
}

auto findSchema(T)(MongoCollection collection, T value)
{
	return collection.find(value._toSchemaBson());
}

auto findOneSchema(T)(MongoCollection collection, T value, U returnFieldSelector, QueryFlags flags = QueryFlags.None)
{
	return collection.find(value._toSchemaBson(), returnFieldSelector, flags);
}

auto findOneSchema(T)(MongoCollection collection, T value)
{
	return collection.find(value._toSchemaBson());
}

auto removeSchema(T)(MongoCollection collection, T value, DeleteFlags flags = DeleteFlags.None)
{
	collection.remove(value._toSchemaBson(), flags);
}

auto insertSchema(T)(MongoCollection collection, T value, InsertFlags flags = InsertFlags.None)
{
	return collection.insert(value._toSchemaBson(), flags);
}

auto updateSchema(T, U)(MongoCollection collection, T value, U update, UpdateFlags flags = UpdateFlags.None)
{
	return collection.insert(value._toSchemaBson(), update, flags);
}

/// Class serializing to a bson date containing a special `now` value that gets translated to the current time when converting to bson.
final struct SchemaDate
{
public:
	this(BsonDate date)
	{
		_time = date.value;
	}

	this(long time)
	{
		_time = time;
	}

	@property auto time() { return _time; }

	static Bson toBson(SchemaDate date)
	{
		if(date._time == -1)
		{
			return Bson(BsonDate.fromStdTime(Clock.currStdTime()));
		}
		else
		{
			return Bson(BsonDate(date._time));
		}
	}

	static SchemaDate fromBson(Bson bson)
	{
		return SchemaDate(bson.get!BsonDate.value);
	}

	static SchemaDate now() { return SchemaDate(-1); }

private:
	long _time;
}

unittest
{
	struct C
	{
		int a = 4;
	}

	struct B
	{
		C cref;
	}

	struct A
	{
		B bref;
	}

	A a;
	a.bref.cref.a = 5;
	auto bson = a._toSchemaBson();
	assert(bson["bref"]["cref"]["a"].get!int == 5);
	A b = bson._toSchemaValue!A();
	assert(b.bref.cref.a == 5);
}

unittest
{
	import std.digest.digest;
	import std.digest.sha;

	enum Activity
	{
		High, Medium, Low
	}

	struct UserSchema
	{
		string username = "Unnamed";
		@binaryType()
		string salt = "foobar";
		@encode("encodePassword")
		@binaryType()
		string password;
		@schemaName("date-created")
		SchemaDate dateCreated = SchemaDate.now;
		Activity activity = Activity.Medium;

		Bson encodePassword(UserSchema user)
		{
			// TODO: Replace with something more secure
			return Bson(BsonBinData(BsonBinData.Type.generic, sha1Of(user.password ~ user.salt)));
		}
	}

	auto user = UserSchema();
	user.password = "12345";
	user.username = "Bob";
	auto bson = user._toSchemaBson();
	assert(bson["username"].get!string == "Bob");
	assert(bson["date-created"].get!(BsonDate).value > 0);
	assert(bson["activity"].get!(int) == cast(int) Activity.Medium);
	assert(bson["salt"].get!(BsonBinData).rawData == cast(ubyte[]) "foobar");
	assert(bson["password"].get!(BsonBinData).rawData == sha1Of(user.password ~ user.salt));

	auto user2 = bson._toSchemaValue!UserSchema();
	assert(user2.username == user.username);
	assert(user2.password != user.password);
	assert(user2.salt == user.salt);
	// dates are gonna differ as `user2` has the current time now and `user` a magic value to get the current time
	assert(user2.activity == user.activity);
}

module mongoschema;

import vibe.data.bson;
import vibe.db.mongo.collection;
import vibe.db.mongo.connection;
import std.datetime;
import std.traits;
import core.time;
import std.typecons : tuple;
import std.datetime : SysTime;

// Bson Attributes

/// Will ignore the variables and not encode/decode them.
enum schemaIgnore;
/// Custom encode function. `func` is the name of the function which must be present as child.
struct encode
{ /++ Function name (needs to be member function) +/ string func;
}
/// Custom decode function. `func` is the name of the function which must be present as child.
struct decode
{ /++ Function name (needs to be member function) +/ string func;
}
/// Encodes the value as binary value. Must be an array with one byte wide elements.
struct binaryType
{ /++ Type to encode +/ BsonBinData.Type type = BsonBinData.Type.generic;
}
/// Custom name for special characters.
struct schemaName
{ /++ Custom replacement name +/ string name;
}

// Mongo Attributes
/// Will create an index with (by default) no flags.
enum mongoForceIndex;
/// Background index construction allows read and write operations to continue while building the index.
enum mongoBackground;
/// Drops duplicates in the database. Only for Mongo versions less than 3.0
enum mongoDropDuplicates;
/// Sparse indexes are like non-sparse indexes, except that they omit references to documents that do not include the indexed field.
enum mongoSparse;
/// MongoDB allows you to specify a unique constraint on an index. These constraints prevent applications from inserting documents that have duplicate values for the inserted fields.
enum mongoUnique;
/// TTL indexes expire documents after the specified number of seconds has passed since the indexed field value; i.e. the expiration threshold is the indexed field value plus the specified number of seconds.
/// Field must be a SchemaDate/BsonDate. You must update the time using collMod.
struct mongoExpire
{
	///
	this(long seconds)
	{
		this.seconds = cast(ulong) seconds;
	}
	///
	this(ulong seconds)
	{
		this.seconds = seconds;
	}
	///
	this(Duration time)
	{
		seconds = cast(ulong) time.total!"msecs";
	}
	///
	ulong seconds;
}

private template isVariable(alias T)
{
	enum isVariable = !is(T) && is(typeof(T)) && !isCallable!T
			&& !is(T == void) && !__traits(isStaticFunction, T) && !__traits(isOverrideFunction, T)
			&& !__traits(isFinalFunction, T) && !__traits(isAbstractFunction, T)
			&& !__traits(isVirtualFunction, T) && !__traits(isVirtualMethod,
					T) && !is(ReturnType!T);
}

private template isVariable(T)
{
	enum isVariable = false; // Types are no variables
}

private template getUDAs(alias symbol, alias attribute)
{
	import std.typetuple : Filter;

	enum isDesiredUDA(alias S) = is(typeof(S) == attribute);
	alias getUDAs = Filter!(isDesiredUDA, __traits(getAttributes, symbol));
}

private Bson memberToBson(T)(T member)
{
	static if (__traits(hasMember, T, "toBson") && is(ReturnType!(typeof(T.toBson)) == Bson))
	{
		// Custom defined toBson
		return T.toBson(member);
	}
	else static if (is(T == Json))
	{
		return Bson.fromJson(member);
	}
	else static if (is(T == BsonBinData) || is(T == BsonObjectID)
			|| is(T == BsonDate) || is(T == BsonTimestamp)
			|| is(T == BsonRegex) || is(T == typeof(null)))
	{
		return Bson(member);
	}
	else static if (!isBasicType!T && !isArray!T && !is(T == enum)
			&& !is(T == Bson) && !isAssociativeArray!T)
	{
		// Mixed in MongoSchema
		return member.toSchemaBson();
	}
	else // Generic value
	{
		static if (is(T == enum))
		{ // Enum value
			return Bson(cast(OriginalType!T) member);
		}
		else static if (isArray!(T) && !isSomeString!T)
		{ // Arrays of anything except strings
			Bson[] values;
			foreach (val; member)
				values ~= memberToBson(val);
			return Bson(values);
		}
		else static if (isAssociativeArray!T)
		{ // Associative Arrays (Objects)
			Bson[string] values;
			foreach (name, val; member)
				values[name] = memberToBson(val);
			return Bson(values);
		}
		else static if (is(T == Bson))
		{ // Already a Bson object
			return member;
		}
		else static if (__traits(compiles, { Bson(member); }))
		{ // Check if this can be passed
			return Bson(member);
		}
		else
		{
			pragma(msg, "Warning falling back to serializeToBson for type " ~ T.stringof);
			return serializeToBson(member);
		}
	}
}

private T bsonToMember(T)(auto ref T member, Bson value)
{
	static if (__traits(hasMember, T, "fromBson") && is(ReturnType!(typeof(T.fromBson)) == T))
	{
		// Custom defined toBson
		return T.fromBson(value);
	}
	else static if (is(T == Json))
	{
		return Bson.fromJson(value);
	}
	else static if (is(T == BsonBinData) || is(T == BsonObjectID)
			|| is(T == BsonDate) || is(T == BsonTimestamp) || is(T == BsonRegex))
	{
		return value.get!T;
	}
	else static if (!isBasicType!T && !isArray!T && !is(T == enum)
			&& !is(T == Bson) && !isAssociativeArray!T)
	{
		// Mixed in MongoSchema
		return value.fromSchemaBson!T();
	}
	else // Generic value
	{
		static if (is(T == enum))
		{ // Enum value
			return cast(T) value.get!(OriginalType!T);
		}
		else static if (isArray!T && !isSomeString!T)
		{ // Arrays of anything except strings
			alias Type = typeof(member[0]);
			T values;
			foreach (val; value)
			{
				values ~= bsonToMember!Type(Type.init, val);
			}
			return values;
		}
		else static if (isAssociativeArray!T)
		{ // Associative Arrays (Objects)
			T values;
			alias ValType = ValueType!T;
			foreach (name, val; value)
				values[name] = bsonToMember!ValType(ValType.init, val);
			return values;
		}
		else static if (is(T == Bson))
		{ // Already a Bson object
			return value;
		}
		else static if (__traits(compiles, { value.get!T(); }))
		{ // Check if this can be passed
			return value.get!T();
		}
		else
		{
			pragma(msg, "Warning falling back to deserializeBson for type " ~ T.stringof);
			return deserializeBson!T(value);
		}
	}
}

/// Generates a Bson document from a struct/class object
Bson toSchemaBson(T)(T obj)
{
	static if (__traits(compiles, cast(T) null) && __traits(compiles, {
			T foo = null;
		}))
	{
		if (obj is null)
			return Bson(null);
	}

	Bson data = Bson.emptyObject;

	static if (hasMember!(T, "_schema_object_id_"))
	{
		if (obj.bsonID.valid)
			data["_id"] = obj.bsonID;
	}

	foreach (memberName; __traits(allMembers, T))
	{
		static if (memberName == "_schema_object_id_")
			continue;
		else static if (__traits(compiles, {
				static s = isVariable!(__traits(getMember, obj, memberName));
			}) && isVariable!(__traits(getMember, obj, memberName)) && !__traits(compiles, {
				static s = __traits(getMember, T, memberName);
			}) // No static members
			 && __traits(compiles, {
				typeof(__traits(getMember, obj, memberName)) t = __traits(getMember,
				obj, memberName);
			}))
		{
			static if (__traits(getProtection, __traits(getMember, obj, memberName)) == "public")
			{
				string name = memberName;
				Bson value;
				static if (!hasUDA!((__traits(getMember, obj, memberName)), schemaIgnore))
				{
					static if (hasUDA!((__traits(getMember, obj, memberName)), schemaName))
					{
						static assert(getUDAs!((__traits(getMember, obj, memberName)), schemaName)
								.length == 1, "Member '" ~ memberName ~ "' can only have one name!");
						name = getUDAs!((__traits(getMember, obj, memberName)), schemaName)[0].name;
					}

					static if (hasUDA!((__traits(getMember, obj, memberName)), encode))
					{
						static assert(getUDAs!((__traits(getMember, obj, memberName)), encode).length == 1,
								"Member '" ~ memberName ~ "' can only have one encoder!");
						mixin("value = obj." ~ getUDAs!((__traits(getMember,
								obj, memberName)), encode)[0].func ~ "(obj);");
					}
					else static if (hasUDA!((__traits(getMember, obj, memberName)), binaryType))
					{
						static assert(isArray!(typeof((__traits(getMember, obj,
								memberName)))) && typeof((__traits(getMember, obj, memberName))[0]).sizeof == 1,
								"Binary member '" ~ memberName
								~ "' can only be an array of 1 byte values");
						static assert(getUDAs!((__traits(getMember, obj, memberName)), binaryType).length == 1,
								"Binary member '" ~ memberName ~ "' can only have one type!");
						BsonBinData.Type type = getUDAs!((__traits(getMember,
								obj, memberName)), binaryType)[0].type;
						value = Bson(BsonBinData(type,
								cast(immutable(ubyte)[])(__traits(getMember, obj, memberName))));
					}
					else
					{
						static if (__traits(compiles, {
								__traits(hasMember, typeof((__traits(getMember,
								obj, memberName))), "toBson");
							}) && __traits(hasMember, typeof((__traits(getMember, obj,
								memberName))), "toBson") && !is(ReturnType!(typeof((__traits(getMember,
								obj, memberName)).toBson)) == Bson))
							pragma(msg, "Warning: ", typeof((__traits(getMember, obj, memberName))).stringof,
									".toBson does not return a vibe.data.bson.Bson struct!");

						value = memberToBson(__traits(getMember, obj, memberName));
					}
					data[name] = value;
				}
			}
		}
	}

	return data;
}

/// Generates a struct/class object from a Bson node
T fromSchemaBson(T)(Bson bson)
{
	static if (__traits(compiles, cast(T) null) && __traits(compiles, {
			T foo = null;
		}))
	{
		if (bson.isNull)
			return null;
	}
	T obj = T.init;

	static if (hasMember!(T, "_schema_object_id_"))
	{
		if (!bson.tryIndex("_id").isNull)
			obj.bsonID = bson["_id"].get!BsonObjectID;
	}

	foreach (memberName; __traits(allMembers, T))
	{
		static if (memberName == "_schema_object_id_")
			continue;
		else static if (__traits(compiles, {
				static s = isVariable!(__traits(getMember, obj, memberName));
			}) && isVariable!(__traits(getMember, obj, memberName)) && !__traits(compiles, {
				static s = __traits(getMember, T, memberName);
			}) // No static members
			 && __traits(compiles, {
				typeof(__traits(getMember, obj, memberName)) t = __traits(getMember,
				obj, memberName);
			}))
		{
			static if (__traits(getProtection, __traits(getMember, obj, memberName)) == "public")
			{
				string name = memberName;
				static if (!hasUDA!((__traits(getMember, obj, memberName)), schemaIgnore))
				{
					static if (hasUDA!((__traits(getMember, obj, memberName)), schemaName))
					{
						static assert(getUDAs!((__traits(getMember, obj, memberName)), schemaName)
								.length == 1, "Member '" ~ memberName ~ "' can only have one name!");
						name = getUDAs!((__traits(getMember, obj, memberName)), schemaName)[0].name;
					}

					// compile time code will still be generated but not run at runtime
					if (bson.tryIndex(name).isNull)
						continue;

					static if (hasUDA!((__traits(getMember, obj, memberName)), decode))
					{
						static assert(getUDAs!((__traits(getMember, obj, memberName)), decode).length == 1,
								"Member '" ~ memberName ~ "' can only have one decoder!");
						mixin("obj." ~ memberName ~ " = obj." ~ getUDAs!((__traits(getMember,
								obj, memberName)), decode)[0].func ~ "(bson);");
					}
					else static if (hasUDA!((__traits(getMember, obj, memberName)), binaryType))
					{
						static assert(isArray!(typeof((__traits(getMember, obj,
								memberName)))) && typeof((__traits(getMember, obj, memberName))[0]).sizeof == 1,
								"Binary member '" ~ memberName
								~ "' can only be an array of 1 byte values");
						static assert(getUDAs!((__traits(getMember, obj, memberName)), binaryType).length == 1,
								"Binary member '" ~ memberName ~ "' can only have one type!");
						assert(bson[name].type == Bson.Type.binData);
						auto data = bson[name].get!(BsonBinData).rawData;
						mixin("obj." ~ memberName ~ " = cast(typeof(obj." ~ memberName ~ ")) data;");
					}
					else
					{
						mixin(
								"obj." ~ memberName ~ " = bsonToMember(obj."
								~ memberName ~ ", bson[name]);");
					}
				}
			}
		}
	}

	return obj;
}

struct DocumentRange(Schema)
{
	private MongoCursor!(Bson, Bson, typeof(null)) _cursor;

	public this(MongoCursor!(Bson, Bson, typeof(null)) cursor)
	{
		_cursor = cursor;
	}

	/**
		Returns true if there are no more documents for this cursor.

		Throws: An exception if there is a query or communication error.
	*/
	@property bool empty()
	{
		return _cursor.empty;
	}

	/**
		Returns the current document of the response.

		Use empty and popFront to iterate over the list of documents using an
		input range interface. Note that calling this function is only allowed
		if empty returns false.
	*/
	@property Schema front()
	{
		return fromSchemaBson!Schema(_cursor.front);
	}

	/**
		Controls the order in which the query returns matching documents.

		This method must be called before starting to iterate, or an exeption
		will be thrown. If multiple calls to $(D sort()) are issued, only
		the last one will have an effect.

		Params:
			order = A BSON object convertible value that defines the sort order
				of the result. This BSON object must be structured according to
				the MongoDB documentation (see below).

		Returns: Reference to the modified original curser instance.

		Throws:
			An exception if there is a query or communication error.
			Also throws if the method was called after beginning of iteration.

		See_Also: $(LINK http://docs.mongodb.org/manual/reference/method/cursor.sort)
	*/
	auto sort(T)(T order)
	{
		_cursor.sort(serializeToBson(order));
		return this;
	}

	/**
		Limits the number of documents that the cursor returns.

		This method must be called before beginnig iteration in order to have
		effect. If multiple calls to limit() are made, the one with the lowest
		limit will be chosen.

		Params:
			count = The maximum number number of documents to return. A value
				of zero means unlimited.

		Returns: the same cursor

		See_Also: $(LINK http://docs.mongodb.org/manual/reference/method/cursor.limit)
	*/
	auto limit(size_t count)
	{
		_cursor.limit(count);
		return this;
	}

	/**
		Skips a given number of elements at the beginning of the cursor.

		This method must be called before beginnig iteration in order to have
		effect. If multiple calls to skip() are made, the one with the maximum
		number will be chosen.

		Params:
			count = The number of documents to skip.

		Returns: the same cursor

		See_Also: $(LINK http://docs.mongodb.org/manual/reference/method/cursor.skip)
	*/
	auto skip(int count)
	{
		_cursor.skip(count);
		return this;
	}

	/**
		Advances the cursor to the next document of the response.

		Note that calling this function is only allowed if empty returns false.
	*/
	void popFront()
	{
		_cursor.popFront();
	}

	/**
		Iterates over all remaining documents.

		Note that iteration is one-way - elements that have already been visited
		will not be visited again if another iteration is done.

		Throws: An exception if there is a query or communication error.
	*/
	int opApply(int delegate(Schema doc) del)
	{
		while (!_cursor.empty)
		{
			auto doc = _cursor.front;
			_cursor.popFront();
			if (auto ret = del(fromSchemaBson!Schema(doc)))
				return ret;
		}
		return 0;
	}
}

class DocumentNotFoundException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc @safe
	{
		super(msg, file, line);
	}
}

/// Mixin for functions for interacting with Mongo collections.
mixin template MongoSchema()
{
	import std.typecons : Nullable;

	static MongoCollection _schema_collection_;
	private BsonObjectID _schema_object_id_;

	/// Returns: the _id value (if set by save or find)
	@property ref BsonObjectID bsonID()
	{
		return _schema_object_id_;
	}

	/// Inserts or updates an existing value.
	void save()
	{
		if (_schema_object_id_.valid)
		{
			_schema_collection_.update(Bson(["_id" : Bson(_schema_object_id_)]),
					this.toSchemaBson(), UpdateFlags.upsert);
		}
		else
		{
			_schema_object_id_ = BsonObjectID.generate;
			auto bson = this.toSchemaBson();
			_schema_collection_.insert(bson);
		}
	}

	/// Removes this object from the collection. Returns false when _id of this is not set.
	bool remove()
	{
		if (!_schema_object_id_.valid)
			return false;
		_schema_collection_.remove(Bson(["_id" : Bson(_schema_object_id_)]),
				DeleteFlags.SingleRemove);
		return true;
	}

	static auto findOneOrThrow(T)(T query)
	{
		Bson found = _schema_collection_.findOne(query);
		if (found.isNull)
			throw new DocumentNotFoundException("Could not find one " ~ typeof(this).stringof);
		return found;
	}

	/// Finds one element with the object id `id`
	static typeof(this) findById(BsonObjectID id)
	{
		return fromSchemaBson!(typeof(this))(findOneOrThrow(Bson(["_id" : Bson(id)])));
	}

	/// Finds one element with the hex id `id`
	static typeof(this) findById(string id)
	{
		return findById(BsonObjectID.fromString(id));
	}

	/// Finds one element using a query.
	static typeof(this) findOne(T)(T query)
	{
		return fromSchemaBson!(typeof(this))(findOneOrThrow(query));
	}

	static Nullable!(typeof(this)) tryFindById(BsonObjectID id)
	{
		Bson found = _schema_collection_.findOne(Bson(["_id" : Bson(id)]));
		if (found.isNull)
			return Nullable!(typeof(this)).init;
		return Nullable!(typeof(this))(fromSchemaBson!(typeof(this))(found));
	}

	static Nullable!(typeof(this)) tryFindById(string id)
	{
		return tryFindById(BsonObjectID.fromString(id));
	}

	static Nullable!(typeof(this)) tryFindOne(T)(T query)
	{
		Bson found = _schema_collection_.findOne(query);
		if (found.isNull)
			return Nullable!(typeof(this)).init;
		return Nullable!(typeof(this))(fromSchemaBson!(typeof(this))(found));
	}

	/// Finds one or more elements using a query.
	static typeof(this)[] find(T)(T query, QueryFlags flags = QueryFlags.None,
			int num_skip = 0, int num_docs_per_chunk = 0)
	{
		typeof(this)[] values;
		foreach (entry; _schema_collection_.find(query, null, flags, num_skip, num_docs_per_chunk))
		{
			values ~= fromSchemaBson!(typeof(this))(entry);
		}
		return values;
	}

	/// Queries all elements from the collection.
	deprecated("use findAll instead") static typeof(this)[] find()
	{
		typeof(this)[] values;
		foreach (entry; _schema_collection_.find())
		{
			values ~= fromSchemaBson!(typeof(this))(entry);
		}
		return values;
	}

	/// Finds one or more elements using a query as range.
	static DocumentRange!(typeof(this)) findRange(T)(T query,
			QueryFlags flags = QueryFlags.None, int num_skip = 0, int num_docs_per_chunk = 0)
	{
		return DocumentRange!(typeof(this))(_schema_collection_.find(serializeToBson(query),
				null, flags, num_skip, num_docs_per_chunk));
	}

	/// Queries all elements from the collection as range.
	static DocumentRange!(typeof(this)) findAll()
	{
		return DocumentRange!(typeof(this))(_schema_collection_.find());
	}

	/// Updates a document.
	static void update(T, U)(T query, U update, UpdateFlags options = UpdateFlags.none)
	{
		_schema_collection_.update(query, update, options);
	}

	/// Updates a document or inserts it when not existent. Shorthand for `update(..., UpdateFlags.upsert)`
	static void upsert(T, U)(T query, U update, UpdateFlags options = UpdateFlags.upsert)
	{
		_schema_collection_.update(query, update, options);
	}

	static void remove(T)(T selector, DeleteFlags flags = DeleteFlags.none)
	{
		_schema_collection_.remove(selector, flags);
	}

	static void removeAll()
	{
		_schema_collection_.remove();
	}

	static void dropTable()
	{
		_schema_collection_.drop();
	}
}

/// Binds a MongoCollection to a Schema. Can only be done once!
void register(T)(MongoCollection collection)
{
	T obj = T.init;

	static if (hasMember!(T, "_schema_collection_"))
	{
		assert(T._schema_collection_.name.length == 0, "Can't register a Schema to 2 collections!");
		T._schema_collection_ = collection;
	}

	foreach (memberName; __traits(allMembers, T))
	{
		static if (__traits(compiles, {
				static s = isVariable!(__traits(getMember, obj, memberName));
			}) && isVariable!(__traits(getMember, obj, memberName)))
		{
			static if (__traits(getProtection, __traits(getMember, obj, memberName)) == "public")
			{
				string name = memberName;
				static if (!hasUDA!((__traits(getMember, obj, memberName)), schemaIgnore))
				{
					static if (hasUDA!((__traits(getMember, obj, memberName)), schemaName))
					{
						static assert(getUDAs!((__traits(getMember, obj, memberName)), schemaName)
								.length == 1, "Member '" ~ memberName ~ "' can only have one name!");
						name = getUDAs!((__traits(getMember, obj, memberName)), schemaName)[0].name;
					}

					IndexFlags flags = IndexFlags.None;
					ulong expires = 0LU;
					bool force;

					static if (hasUDA!((__traits(getMember, obj, memberName)), mongoForceIndex))
					{
						force = true;
					}
					static if (hasUDA!((__traits(getMember, obj, memberName)), mongoBackground))
					{
						flags |= IndexFlags.Background;
					}
					static if (hasUDA!((__traits(getMember, obj, memberName)),
							mongoDropDuplicates))
					{
						flags |= IndexFlags.DropDuplicates;
					}
					static if (hasUDA!((__traits(getMember, obj, memberName)), mongoSparse))
					{
						flags |= IndexFlags.Sparse;
					}
					static if (hasUDA!((__traits(getMember, obj, memberName)), mongoUnique))
					{
						flags |= IndexFlags.Unique;
					}
					static if (hasUDA!((__traits(getMember, obj, memberName)), mongoExpire))
					{
						static assert(getUDAs!((__traits(getMember, obj, memberName)), mongoExpire).length == 1,
								"Member '" ~ memberName ~ "' can only have one expiry value!");
						flags |= IndexFlags.ExpireAfterSeconds;
						expires = getUDAs!((__traits(getMember, obj, memberName)), mongoExpire)[0]
							.seconds;
					}

					if (flags != IndexFlags.None || force)
						collection.ensureIndex([tuple(name, 1)], flags, dur!"seconds"(expires));
				}
			}
		}
	}
}

/// Class serializing to a bson date containing a special `now` value that gets translated to the current time when converting to bson.
final struct SchemaDate
{
public:
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
	@property auto time()
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

	/// Magic value setting the date to the current time stamp when serializing.
	static SchemaDate now()
	{
		return SchemaDate(-1);
	}

	SysTime toSysTime()
	{
		return BsonDate(_time).toSysTime();
	}

	BsonDate toBsonDate()
	{
		return BsonDate(_time);
	}

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
	auto bson = a.toSchemaBson();
	assert(bson["bref"]["cref"]["a"].get!int == 5);
	A b = bson.fromSchemaBson!A();
	assert(b.bref.cref.a == 5);
}

unittest
{
	import std.digest.digest;
	import std.digest.sha;

	enum Activity
	{
		High,
		Medium,
		Low
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
	auto bson = user.toSchemaBson();
	assert(bson["username"].get!string == "Bob");
	assert(bson["date-created"].get!(BsonDate).value > 0);
	assert(bson["activity"].get!(int) == cast(int) Activity.Medium);
	assert(bson["salt"].get!(BsonBinData).rawData == cast(ubyte[]) "foobar");
	assert(bson["password"].get!(BsonBinData).rawData == sha1Of(user.password ~ user.salt));

	auto user2 = bson.fromSchemaBson!UserSchema();
	assert(user2.username == user.username);
	assert(user2.password != user.password);
	assert(user2.salt == user.salt);
	// dates are gonna differ as `user2` has the current time now and `user` a magic value to get the current time
	assert(user2.dateCreated != user.dateCreated);
	assert(user2.activity == user.activity);
}

unittest
{
	import vibe.db.mongo.mongo;
	import std.digest.sha;
	import std.exception;
	import std.array;

	auto client = connectMongoDB("localhost");
	auto database = client.getDatabase("test");
	MongoCollection users = database["users"];
	users.remove(); // Clears collection

	struct User
	{
		mixin MongoSchema;

		@mongoUnique string username;
		@binaryType()
		ubyte[] hash;
		@schemaName("profile-picture")
		string profilePicture;
		auto registered = SchemaDate.now;
	}

	users.register!User;

	assert(User.findAll().array.length == 0);

	User user;
	user.username = "Example";
	user.hash = sha512Of("password123");
	user.profilePicture = "example-avatar.png";

	assertNotThrown(user.save());

	User user2;
	user2.username = "Bob";
	user2.hash = sha512Of("foobar");
	user2.profilePicture = "bob-avatar.png";

	assertNotThrown(user2.save());

	User faker;
	faker.username = "Example";
	faker.hash = sha512Of("PASSWORD");
	faker.profilePicture = "example-avatar.png";

	assertThrown(faker.save());
	// Unique username

	faker.username = "Example_";
	assertNotThrown(faker.save());

	user.username = "NewExample";
	user.save();

	auto actualFakeID = faker.bsonID;
	faker = User.findOne(["username" : "NewExample"]);

	assert(actualFakeID != faker.bsonID);

	foreach (usr; User.findAll)
	{
		usr.profilePicture = "default.png"; // Reset all profile pictures
		usr.save();
	}
	user = User.findOne(["username" : "NewExample"]);
	user2 = User.findOne(["username" : "Bob"]);
	faker = User.findOne(["username" : "Example_"]);
	assert(user.profilePicture == user2.profilePicture
			&& user2.profilePicture == faker.profilePicture && faker.profilePicture == "default.png");

	User user3;
	user3.username = "User123";
	user3.hash = sha512Of("486951");
	user3.profilePicture = "new.png";
	User.upsert(["username" : "User123"], user3.toSchemaBson);
	user3 = User.findOne(["username" : "User123"]);
	assert(user3.hash == sha512Of("486951"));
	assert(user3.profilePicture == "new.png");
}

unittest
{
	import vibe.db.mongo.mongo;
	import mongoschema.aliases : name, ignore, unique, binary;
	import std.digest.sha;
	import std.digest.md;

	auto client = connectMongoDB("localhost");

	struct Permission
	{
		string name;
		int priority;
	}

	struct User
	{
		mixin MongoSchema;

		@unique string username;

		@binary()
		ubyte[] hash;
		@binary()
		ubyte[] salt;

		@name("profile-picture")
		string profilePicture = "default.png";

		Permission[] permissions;

	@ignore:
		int sessionID;
	}

	auto coll = client.getCollection("test.users2");
	coll.remove();
	coll.register!User;

	User register(string name, string password)
	{
		User user;
		user.username = name;
		user.salt = md5Of(name).dup;
		user.hash = sha512Of(cast(ubyte[]) password ~ user.salt).dup;
		user.permissions ~= Permission("forum.access", 1);
		user.save();
		return user;
	}

	User find(string name)
	{
		return User.findOne(["username" : name]);
	}

	User a = register("foo", "bar");
	User b = find("foo");
	assert(a == b);
}

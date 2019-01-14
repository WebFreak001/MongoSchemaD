module mongoschema;

import core.time;
import std.traits;
import std.typecons : BitFlags, isTuple;
public import vibe.data.bson;
public import vibe.db.mongo.collection;
public import vibe.db.mongo.connection;

public import mongoschema.date;
public import mongoschema.db;

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

package template isVariable(alias T)
{
	enum isVariable = !is(T) && is(typeof(T)) && !isCallable!T
			&& !is(T == void) && !__traits(isStaticFunction, T) && !__traits(isOverrideFunction, T)
			&& !__traits(isFinalFunction, T) && !__traits(isAbstractFunction, T)
			&& !__traits(isVirtualFunction, T) && !__traits(isVirtualMethod,
					T) && !is(ReturnType!T);
}

package template isVariable(T)
{
	enum isVariable = false; // Types are no variables
}

package Bson memberToBson(T)(T member)
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
	else static if (is(T == enum))
	{ // Enum value
		return Bson(cast(OriginalType!T) member);
	}
	else static if (is(T == BitFlags!(Enum, Unsafe), Enum, alias Unsafe))
	{ // std.typecons.BitFlags
		return Bson(cast(OriginalType!Enum) member);
	}
	else static if (isArray!(T) && !isSomeString!T || isTuple!T)
	{ // Arrays of anything except strings
		Bson[] values;
		foreach (val; member)
			values ~= memberToBson(val);
		return Bson(values);
	}
	else static if (isAssociativeArray!T)
	{ // Associative Arrays (Objects)
		Bson[string] values;
		static assert(is(KeyType!T == string), "Associative arrays must have strings as keys");
		foreach (string name, val; member)
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
	else static if (!isBasicType!T)
	{
		// Mixed in MongoSchema
		return member.toSchemaBson();
	}
	else // Generic value
	{
		pragma(msg, "Warning falling back to serializeToBson for type " ~ T.stringof);
		return serializeToBson(member);
	}
}

package T bsonToMember(T)(auto ref T member, Bson value)
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
	else static if (is(T == enum))
	{ // Enum value
		return cast(T) value.get!(OriginalType!T);
	}
	else static if (is(T == BitFlags!(Enum, Unsafe), Enum, alias Unsafe))
	{ // std.typecons.BitFlags
		return cast(T) cast(Enum) value.get!(OriginalType!Enum);
	}
	else static if (isTuple!T)
	{ // Tuples
		auto bsons = value.get!(Bson[]);
		T values;
		foreach (i, val; values)
		{
			values[i] = bsonToMember!(typeof(val))(values[i], bsons[i]);
		}
		return values;
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
		static assert(is(KeyType!T == string), "Associative arrays must have strings as keys");
		alias ValType = ValueType!T;
		foreach (string name, val; value)
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
	else static if (!isBasicType!T)
	{
		// Mixed in MongoSchema
		return value.fromSchemaBson!T();
	}
	else // Generic value
	{
		pragma(msg, "Warning falling back to deserializeBson for type " ~ T.stringof);
		return deserializeBson!T(value);
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
					if (bson.tryIndex(name).isNull || bson[name].type == Bson.Type.undefined)
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

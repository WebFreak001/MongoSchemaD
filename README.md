# MongoSchemaD

A simple library for vibe.d adding support for structured Bson
data using structs/classes and functions to simplify saving,
updating and finding Mongo documents.

Can also be used without MongoDB for Bson (de)serialization.

## Example

```d
import vibe.db.mongo.mongo;
import mongoschema;
import mongoschema.aliases : name, ignore, unique, binary;

struct Permission
{
	string name;
	int priority;
}

struct User
{
	mixin MongoSchema; // Adds save, update, etc.

	@unique
	string username;

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

User registerNewUser(string name, string password)
{
	User user;
	user.username = name;
	user.salt = generateSalt().dup; // needs dup because array gets messed up otherwise when leaving function
	user.hash = complicatedHashFunction(password, user.salt).dup;
	user.permissions ~= Permission("forum.access", 1);
	// Automatically serializes and puts the object in the registered database
	// If save was already called or the object got retrieved from the
	// collection `save()` will just update the existing object.
	user.save();
	// ->
	// {
	//   username: name,
	//   hash: <binary>,
	//   salt: <binary>,
	//   profile-picture: "default.png",
	//   permissions: [{
	//     name: "forum.access",
	//     priority: 1
	//   }]
	// }
	return user;
}

// convenience method, could also put this in the User struct
User find(string name)
{
	return User.findOneOrThrow(["username": name]);
}

void main()
{
	// connect as usual
	auto client = connectMongoDB("localhost");

	// before accessing any MongoSchemaD functions on a struct, register the
	// structs using the `MongoCollection.register!T` function globally.

	// Links the `test.users` collection to the `User` struct.
	client.getCollection("test.users").register!User;
}
```

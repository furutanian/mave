begin

	require 'depot'

	class XDBM < Depot

		NOLOCK = Depot::ONOLCK
		READER = Depot::OREADER

		def initialize(name, mode = 0666, flags = Depot::OWRITER | Depot::OCREAT)
			flags ||= (Depot::OWRITER | Depot::OCREAT)
			super(name + '.qdb', flags | Depot::OLCKNB)
			File.chmod(mode & ~File.umask, name + '.qdb')
		end

		def delete(key)
			value = self[key] and super
			value
		end

		def reorganize
#			optimize
		end
	end

rescue LoadError

	require 'gdbm'

	class XDBM < GDBM

		NOLOCK = GDBM::NOLOCK
		READER = GDBM::READER

		def initialize(name, mode = 0666, flags = GDBM::WRCREAT)
			super(name + '.gdb', mode, flags)
		end

		def reorganize
#			super
		end
	end
end

__END__


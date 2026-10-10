package io.byterepair.entoli

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap
import io.flutter.util.PathUtils
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

// The workspaces in the Files app and in every picker that asks for a file or a
// folder. See "The workspaces in the Files app" in AGENTS.md.
//
// Queried with no Flutter engine running — the Files app starts the process by
// asking — so the layout `AppConfig` composes is read off the disk here, and
// `isWorkspacePath` with `projectOf` is the whole of that agreement.
class WorkspaceProvider : DocumentsProvider() {
    override fun onCreate() = true

    override fun queryRoots(projection: Array<String>?): Cursor {
        val cursor = MatrixCursor(ROOT_COLUMNS)
        val info = app.applicationInfo
        cursor.newRow().apply {
            add(Root.COLUMN_ROOT_ID, "workspaces")
            // Every project, which is what `projects/` holds.
            add(Root.COLUMN_DOCUMENT_ID, PROJECT)
            add(Root.COLUMN_TITLE, info.loadLabel(app.packageManager).toString())
            add(Root.COLUMN_SUMMARY, "Workspaces")
            add(Root.COLUMN_FLAGS, Root.FLAG_LOCAL_ONLY or Root.FLAG_SUPPORTS_IS_CHILD)
            // `<application android:icon>`, so this does not follow the user's
            // icon setting: a root is the app's, like AgentService's.
            add(Root.COLUMN_ICON, info.icon)
        }
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<String>?): Cursor {
        val cursor = MatrixCursor(DOCUMENT_COLUMNS)
        if (documentId.startsWith(PROJECT)) {
            cursor.addProject(projectOf(documentId))
            return cursor
        }
        val found = locate(documentId)
        cursor.addFile(documentId, found.file, nameOf(found))
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<String>?,
        sortOrder: String?,
    ): Cursor {
        val cursor = MatrixCursor(DOCUMENT_COLUMNS)
        if (parentDocumentId.startsWith(PROJECT)) {
            cursor.addProjectChildren(projectOf(parentDocumentId))
            return cursor
        }
        val parent = locate(parentDocumentId)
        parent.file.listFiles()?.sortedWith(BY_NAME)?.forEach { child ->
            // Resolved rather than trusted: the agent's own commands run in
            // these directories, so a link out of one is something it can have
            // been told to leave behind.
            if (contains(parent.workspace, child.canonicalFile)) {
                cursor.addFile("$parentDocumentId/${child.name}", child, child.name)
            }
        }
        return cursor
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        if (ParcelFileDescriptor.parseMode(mode) != ParcelFileDescriptor.MODE_READ_ONLY) {
            throw UnsupportedOperationException("Entoli's workspaces are read-only here")
        }
        return ParcelFileDescriptor.open(
            locate(documentId).file,
            ParcelFileDescriptor.MODE_READ_ONLY,
        )
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean = when {
        parentDocumentId == PROJECT -> documentId != PROJECT
        parentDocumentId.startsWith(PROJECT) ->
            documentId.startsWith("projects/${projectOf(parentDocumentId)}/")
        else -> documentId.startsWith("$parentDocumentId/")
    }

    private class Found(val file: File, val workspace: File)

    /**
     * Only the workspaces are reachable: a document id has to name one before
     * anything under it resolves, and has to still be inside it once every link
     * in it has been followed.
     */
    private fun locate(documentId: String): Found {
        val segments = documentId.split('/')
        if (segments.any { it.isEmpty() || it == "." || it == ".." }) throw notFound(documentId)
        if (!isWorkspacePath(segments)) throw notFound(documentId)
        val file = File(dataDir, segments.joinToString(File.separator)).canonicalFile
        val workspace = File(
            dataDir,
            segments.take(WORKSPACE_DEPTH).joinToString(File.separator),
        ).canonicalFile
        if (!contains(workspace, file)) throw notFound(documentId)
        return Found(file, workspace)
    }

    /**
     * The project a project document id names, empty for the root — which is
     * every project rather than one. Held to `AppConfig.projectDir`'s rule of
     * one directory under `projects/`, because a tree grant lets the app holding
     * it compose ids of its own: `:..` is one that arrives rather than one that
     * was handed out.
     */
    private fun projectOf(documentId: String): String {
        val name = documentId.substring(PROJECT.length)
        if (name.isNotEmpty() && !isProjectDir(name)) throw notFound(documentId)
        return name
    }

    /**
     * Whether a document id names a workspace or something inside one — so
     * `chats/`, holding the conversation and what was attached to it, is not in
     * the tree and cannot be asked for. A chat's own workspace is inside the
     * project's, so there is one shape to name and not two.
     */
    private fun isWorkspacePath(segments: List<String>) =
        segments.size >= WORKSPACE_DEPTH &&
            segments[0] == "projects" &&
            isProjectDir(segments[1]) &&
            segments[2] == "workspace"

    private fun dirOf(project: String) = File(dataDir, "projects/$project")

    private fun MatrixCursor.addProjectChildren(project: String) {
        if (project.isEmpty()) {
            projectDirs().forEach { addProject(it.name) }
            return
        }
        val dir = dirOf(project)
        val workspace = File(dir, "workspace")
        if (!workspace.isDirectory) return
        val id = "projects/$project/workspace"
        addFile(id, workspace, WORKSPACE)
        // The chats' own, which are folders in the workspace above them. Named
        // here as well as reachable by opening `chats/`, since a title is what
        // the user picked one by.
        File(workspace, "chats").listFiles()?.sortedWith(BY_NAME)?.forEach { chat ->
            if (chat.isDirectory) {
                addFile("$id/chats/${chat.name}", chat, chatTitle(dir, chat.name))
            }
        }
    }

    // `everyProject`, in lib/domain/project.dart: the default one first, the
    // rest by name.
    private fun projectDirs(): List<File> =
        File(dataDir, "projects").listFiles()
            ?.filter { it.isDirectory && isProjectDir(it.name) }
            ?.sortedWith(compareBy<File> { it.name != DEFAULT }.thenComparing(BY_NAME))
            ?: emptyList()

    private fun MatrixCursor.addProject(project: String) {
        newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, PROJECT + project)
            add(
                Document.COLUMN_DISPLAY_NAME,
                when {
                    // The root, which is every project rather than one.
                    project.isEmpty() -> "Workspaces"
                    // `defaultProjectLabel`, in lib/domain/project.dart.
                    project == DEFAULT -> "Default"
                    else -> project
                },
            )
            add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
            add(Document.COLUMN_FLAGS, 0)
        }
    }

    private fun MatrixCursor.addFile(documentId: String, file: File, name: String) {
        newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, documentId)
            add(Document.COLUMN_DISPLAY_NAME, name)
            add(Document.COLUMN_MIME_TYPE, mimeOf(file))
            add(Document.COLUMN_LAST_MODIFIED, file.lastModified())
            add(Document.COLUMN_FLAGS, 0)
            if (file.isFile) add(Document.COLUMN_SIZE, file.length())
        }
    }

    // A project's workspace by the word the explorer uses, a chat's by the title
    // of the chat it belongs to, and anything else by its own name.
    private fun nameOf(found: Found): String = when {
        found.file == found.workspace -> WORKSPACE
        found.file.parentFile == File(found.workspace, "chats") ->
            chatTitle(found.workspace.parentFile!!, found.file.name)
        else -> found.file.name
    }

    // The chat's title lives with the conversation rather than in the workspace
    // named after it. Read behind the app's back, which is safe for the reason
    // the documents are written through a rename: there is no half-written
    // `state.json` to catch.
    private fun chatTitle(projectDir: File, chatId: String): String = try {
        JSONObject(File(projectDir, "chats/$chatId/state.json").readText())
            .optString("title").ifBlank { chatId }
    } catch (e: Exception) {
        chatId
    }

    // The shape rule, `isProjectDirName` in lib/domain/project.dart, bar
    // `default`, a name Dart has no need of because `null` is the default
    // project there, and a directory like any other here. And a workspace
    // that is not shared is not in the tree either, `UNBROWSED` below: a
    // chat that must not reach past itself is not one whose scratch the
    // Files app browses.
    private fun isProjectDir(name: String) =
        name.isNotEmpty() && !name.startsWith(".") && !name.contains('/') && name !in UNBROWSED

    // `viewerMime`, in lib/data/mime.dart: octet-stream throws away the one fact
    // that decides whether anything opens the file at all, so an unrecognised
    // one is offered as text, which is what most of a workspace is.
    private fun mimeOf(file: File): String = when {
        file.isDirectory -> Document.MIME_TYPE_DIR
        else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
            ?: "text/plain"
    }

    private fun contains(dir: File, file: File) =
        file == dir || file.path.startsWith(dir.path + File.separator)

    private fun notFound(documentId: String) =
        FileNotFoundException("No workspace document at $documentId")

    // The call path_provider's getApplicationDocumentsDirectory makes, so this
    // is where `platformDataDir` put the data directory rather than a guess at
    // it. Lazy, not eager: a provider is constructed during process start, and
    // nothing about this belongs there.
    private val dataDir by lazy { File(PathUtils.getDataDirectory(app), "agent-chat") }

    private val app get() = context!!

    private companion object {
        // A document id is either a project — ":" for the root, which is all of
        // them, and ":<name>" for one — or a path relative to the data
        // directory, which is what every file and folder in a workspace is.
        // Nothing can be read as both: a real path always starts `projects`.
        const val PROJECT = ":"

        // `defaultProjectDir`, in lib/domain/project.dart.
        const val DEFAULT = "default"

        // The built-in projects' directories whose workspace is not shared,
        // in lib/domain/builtin_project.dart, restated because no Dart is
        // running when this is queried. Kept in step by hand, like `DEFAULT`.
        // A built-in that shared its workspace would be in the tree like any
        // other project, and would leave this set.
        val UNBROWSED = setOf("anonymous")

        // `projects/<name>/workspace`, which every reachable path starts with.
        const val WORKSPACE_DEPTH = 3

        // What the explorer calls a workspace, and every workspace is a
        // directory called `workspace`.
        const val WORKSPACE = "Workspace"

        // `listWorkspace`'s order, in lib/domain/workspace.dart, minus the
        // folders-first half: DocumentsUI re-sorts by whatever the user picked,
        // so a second stat per row to group them buys nothing.
        val BY_NAME: Comparator<File> = compareBy(String.CASE_INSENSITIVE_ORDER) { it.name }

        val ROOT_COLUMNS = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY,
            Root.COLUMN_FLAGS,
            Root.COLUMN_ICON,
        )

        // The projection a query asks for is ignored, deliberately: a cursor may
        // carry more columns than were asked for, and MatrixCursor throws on an
        // `add` naming a column the projection left out.
        val DOCUMENT_COLUMNS = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
            Document.COLUMN_SIZE,
        )
    }
}
